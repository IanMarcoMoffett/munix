const std = @import("std");
const vmm = @import("root").vmm;
const smp = @import("root").smp;
const arch = @import("root").arch;
const irq = @import("root").dev.irq;
const acpi = @import("root").dev.acpi;
const allocator = @import("root").allocator;
const sync = @import("../util/sync.zig");
const sink = std.log.scoped(.apic);

pub var io_apics: std.ArrayList(IoApic) = undefined;
pub var slots: std.ArrayList(irq.IrqSlot) = undefined;
pub var slots_lock: sync.SpinMutex = .{};
var ic: LocalApic = .{};

inline fn regoff(n: usize) u32 {
    return @intCast(u32, 0x10 + n * 2);
}

pub const LocalApic = struct {
    mmio_base: u64 = 0xFFFF8000FEE00000,

    // general regs
    const REG_VER = 0x30;
    const REG_EOI = 0xB0;
    const REG_SPURIOUS = 0xF0;

    pub fn read(self: *LocalApic, reg: u32) u32 {
        return @intToPtr(*volatile u32, self.mmio_base + reg).*;
    }

    pub fn write(self: *LocalApic, reg: u32, value: u32) void {
        @intToPtr(*volatile u32, self.mmio_base + reg).* = value;
    }

    pub fn init(self: *LocalApic) void {
        var mmio_base = vmm.toHigherHalf(arch.rdmsr(0x1B) & 0xFFFFF000);
        if (mmio_base != self.mmio_base) {
            sink.warn("mmio base 0x{X:0>16} is not the x86 default!", .{mmio_base});
            self.mmio_base = mmio_base;
        }

        // map the APIC as UC
        var aligned_base: u64 = std.mem.alignBackward(mmio_base, 0x200000);
        var map_flags = vmm.MapFlags{ .read = true, .write = true, .cache_type = .uncached };
        vmm.kernel_pagemap.unmapPage(aligned_base);
        vmm.kernel_pagemap.mapPage(map_flags, aligned_base, vmm.fromHigherHalf(aligned_base), true);

        // enable the APIC
        self.enable();
    }

    pub fn enable(self: *LocalApic) void {
        // enable the APIC
        arch.wrmsr(0x1B, arch.rdmsr(0x1B) | (1 << 11));
        self.write(REG_SPURIOUS, self.read(REG_SPURIOUS) | (1 << 8) | 0xFF);
    }

    pub fn submitEoi(self: *LocalApic, pin: u8) void {
        _ = pin;
        self.write(REG_EOI, 0);
    }
};

pub const IoApic = struct {
    pins: std.ArrayList(irq.IrqPin) = undefined,
    mmio_base: u64 = 0,
    gsi_base: u32 = 0,
    pin_count: u32 = 0,

    const REG_ID = 0x0;
    const REG_VER = 0x1;
    const REG_ARB = 0x2;

    const PinContext = struct {
        parent: *IoApic,
        index: usize,
    };

    pub fn read(self: *IoApic, reg: u32) u32 {
        @intToPtr(*volatile u32, self.mmio_base).* = reg;
        return @intToPtr(*volatile u32, self.mmio_base + 0x10).*;
    }

    pub fn write(self: *IoApic, reg: u32, value: u32) void {
        @intToPtr(*volatile u32, self.mmio_base).* = reg;
        @intToPtr(*volatile u32, self.mmio_base + 0x10).* = value;
    }

    pub fn mask(pin: *irq.IrqPin, state: bool) void {
        const pctx = @ptrCast(*align(1) PinContext, pin.context);
        const reg = pctx.parent.read(regoff(pctx.index));

        if (state) {
            pctx.parent.write(regoff(pctx.index), reg | (1 << 16));
        } else {
            pctx.parent.write(regoff(pctx.index), reg & ~@as(u32, (1 << 16)));
        }
    }

    pub fn eoi(pin: *irq.IrqPin) void {
        _ = pin;
        ic.submitEoi(0);
    }

    pub fn configure(pin: *irq.IrqPin, level: bool, high: bool) irq.IrqType {
        const pctx = @ptrCast(*align(1) PinContext, pin.context);
        var flags: u32 = 0;
        var vec: u32 = 0;

        if (level)
            flags |= (1 << 15);

        if (!high)
            flags |= (1 << 13);

        slots_lock.lock();
        defer slots_lock.unlock();

        for (slots.items, 0..) |slot, i| {
            if (slot.active)
                continue;

            slots.items[i].link(pin);
            vec = @intCast(u32, i);
        }

        if (vec == 0)
            @panic("Out of IRQ vectors! (IO-APIC)");

        pctx.parent.write(regoff(pctx.index), flags | vec);
        if (level)
            return .level;

        return .edge;
    }

    pub fn setup(self: *IoApic) !void {
        self.pins = std.ArrayList(irq.IrqPin).init(allocator());
        self.pin_count = ((self.read(REG_VER) >> 16) & 0xFF) + 1;
        sink.debug("IO-APIC({}): a total of {} pins supported (base={})", .{ io_apics.items.len - 1, self.pin_count, self.gsi_base });

        for (0..self.pin_count) |i| {
            var pin_name = try std.fmt.allocPrint(allocator(), "ioapic-{}", .{i});
            var pin = try allocator().create(irq.IrqPin);
            var context = try allocator().create(PinContext);
            errdefer allocator().delete(pin);

            context.* = .{
                .parent = self,
                .index = i,
            };

            pin.* = .{
                .context = context,
                .setMask = &IoApic.mask,
                .eoi = &IoApic.eoi,
                .configure = &IoApic.configure,
                .name = pin_name,
            };
        }
    }
};

pub fn init() !void {
    // create the pins, and set the lower 31 as reserved
    io_apics = std.ArrayList(IoApic).init(allocator());
    slots = std.ArrayList(irq.IrqSlot).init(allocator());
    for (0..256) |i| {
        if (i <= 31) {
            try slots.append(.{ .active = true });
        } else {
            try slots.append(.{});
        }
    }

    // parse the MADT for IO-APIC entries
    var madt = acpi.getTable("APIC") orelse @panic("Unable to find MADT (required for boot)");
    var contents = madt.getContents()[8..];

    while (contents.len >= 2) {
        const typ = contents[0];
        const len = contents[1];

        if (len >= contents.len)
            break;

        const data = contents[2..len];

        switch (typ) {
            1 => { // IO-APIC
                try io_apics.append(.{
                    .mmio_base = vmm.toHigherHalf(std.mem.readIntNative(u32, data[2..6])),
                    .gsi_base = std.mem.readIntNative(u32, data[6..10]),
                });

                try io_apics.items[io_apics.items.len - 1].setup();
            },
            else => {},
        }

        contents = contents[std.math.max(2, len)..];
    }

    ic.init();
}

pub fn enable() void {
    ic.enable();
}