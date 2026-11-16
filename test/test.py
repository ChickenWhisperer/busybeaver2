# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

TAPE_CELLS = 16384
STEPS_TO_CHECK = 20000  # the full run is 47,176,870 steps - far too long for CI

# 1RB1LC_1RC1RB_1RD0LE_1LA1LD_1RZ0LA : (state, symbol) -> (write, move, next)
BB5 = {
    ("A", 0): (1, +1, "B"), ("A", 1): (1, -1, "C"),
    ("B", 0): (1, +1, "C"), ("B", 1): (1, +1, "B"),
    ("C", 0): (1, +1, "D"), ("C", 1): (0, -1, "E"),
    ("D", 0): (1, -1, "A"), ("D", 1): (1, -1, "D"),
    ("E", 0): (1, +1, "H"), ("E", 1): (0, -1, "A"),
}


def reference_writes(n):
    """(address, written symbol) for the first n steps from a blank tape."""
    tape, head, state, out = {}, 0, "A", []
    for _ in range(n):
        write, move, state_next = BB5[(state, tape.get(head, 0))]
        out.append((head % TAPE_CELLS, write))
        tape[head] = write
        head += move
        state = state_next
        assert state != "H"
    return out


async def monitor_writes(dut, log):
    """Record {driving, data, address} at the end of every WE# pulse."""
    while True:
        await RisingEdge(dut.we_n)
        log.append(dut.mon.value.to_unsigned())


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # 2 MHz clock: two clocks per Turing-machine step
    clock = Clock(dut.clk, 500, unit="ns")
    cocotb.start_soon(clock.start())

    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 4)

    writes = []
    cocotb.start_soon(monitor_writes(dut, writes))

    dut._log.info("After reset the machine is halted: no writes")
    await ClockCycles(dut.clk, 50)
    assert writes == []

    dut._log.info("SCAN walks the head without writing")
    start = dut.addr.value.to_unsigned()
    dut.ui_in.value = 2
    await ClockCycles(dut.clk, 40)
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 10)
    moved = (dut.addr.value.to_unsigned() - start) % TAPE_CELLS
    assert 17 <= moved <= 22, f"head moved {moved} cells"
    assert writes == []

    dut._log.info("CLEAR wipes all 16384 cells, then waits")
    dut.ui_in.value = 1
    await ClockCycles(dut.clk, 33000)
    assert len(writes) == TAPE_CELLS, f"{len(writes)} clear writes"
    for i, w in enumerate(writes):
        assert w == (1 << 15) | i, f"clear write {i}: {w:#06x}"
    writes.clear()
    await ClockCycles(dut.clk, 100)
    assert writes == [], "WE# must stay quiet while CLEAR is held"

    dut._log.info("Run and compare against the reference machine")
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 2 * STEPS_TO_CHECK + 20)
    assert len(writes) >= STEPS_TO_CHECK, f"only {len(writes)} steps"
    for i, (addr, sym) in enumerate(reference_writes(STEPS_TO_CHECK)):
        expect = (1 << 15) | (sym << 14) | addr
        assert writes[i] == expect, f"step {i + 1}: got {writes[i]:#06x}, want {expect:#06x}"

    assert dut.contention.value == 0, "chip drove the data bus before WE# went low"

    dut._log.info("CLEAR again restarts the machine from a blank tape")
    dut.ui_in.value = 1
    await ClockCycles(dut.clk, 33000)
    writes.clear()
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 2 * 200 + 20)
    for i, (addr, sym) in enumerate(reference_writes(200)):
        assert writes[i] == (1 << 15) | (sym << 14) | addr, f"rerun step {i + 1}"
