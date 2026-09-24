## QoS-Aware Packet Router – SystemVerilog RTL & Verification

## Overview

This project implements and verifies a QoS-aware multi-input, multi-output packet router using SystemVerilog.
The design supports priority-based arbitration, round-robin fairness, and robust backpressure handling, and is verified using a self-checking, protocol-aware testbench.

The focus of this project is front-end ASIC RTL design and functional verification, aligned with the responsibilities of an ASIC Design Verification Engineer.

## Project Objectives

Design a synthesizable packet router RTL (ASIC-ready)
Implement QoS arbitration (priority + round-robin fairness)
Handle packet-level locking (no mid-packet preemption)
Support ready/valid backpressure
Build a non-UVM, structured SystemVerilog testbench
Verify correctness using self-checking tests
Avoid toy examples (ALU/counter) and focus on real protocol behavior

## Architecture Summary
Router Features
Inputs: 4 independent packet sources
Outputs: 2 packet sinks

# Packet Format:
Destination (dst)
Priority (prio)
Payload length (len)
Start-of-frame (sof)
End-of-packet (last)

Per-input FIFOs for buffering
Packet-level locking ensures atomic packet forwarding

# QoS arbitration modes:
Priority-based arbitration
Round-robin tie-breaking for fairness

# Backpressure support:
Output stalls propagate correctly
Data is held stable during stalls

## Arbitration Logic

# If multiple inputs target the same output:
Higher priority wins
If priorities are equal → Round-robin arbitration

# Once a packet is granted:
The output remains locked to that input until last is transferred
Prevents packet interleaving and protocol violations

## Verification Strategy

The project uses a procedural, self-checking SystemVerilog testbench (non-UVM) that mirrors industry verification roles:

Verification Role	Implementation
Generator:	Directed and concurrent stimulus blocks
Driver:	Protocol-aware packet send tasks
Monitor:	Passive observation of output interfaces
Scoreboard:	Counters, assertions, and PASS/FAIL checks
Interface:	SystemVerilog interface with ready/valid

Timeouts are included to prevent deadlock and infinite simulation hangs.

## Test Coverage
#TEST 1 – QoS Priority Enforcement

Goal:
Verify that higher-priority packets are always forwarded before lower-priority packets when contending for the same output.

Result:
✔ High-priority packet observed first at output
✔ Packet integrity preserved

#TEST 2 – Round-Robin Fairness (No Starvation)

Goal:
Verify that equal-priority inputs targeting the same output are serviced fairly.

Method:

Inject repeated contention from two inputs

Track observed packet headers at output

Ensure both inputs are serviced

Result:
✔ Both inputs observed multiple times
✔ No starvation detected

#TEST 3 – Backpressure Stall Handling

Goal:
Verify correct behavior when output ready is deasserted mid-packet.

Checks Performed:

Output holds data, sof, last, and header fields stable

valid remains asserted during stall

Packet resumes correctly once ready is reasserted

Result:
✔ Data held stable across multiple stall cycles
✔ Packet completed successfully after stall

## Simulation Results

All tests complete successfully with clear PASS indicators:

PASS(TEST1): Priority enforcement verified
PASS(TEST2): Round-robin fairness verified
PASS(TEST3): Backpressure stall handled correctly
ALL TESTS PASSED


Waveforms confirm protocol stability during stalls.

## ASIC Design Flow Context

This project focuses on the front-end ASIC flow:

✔ Specification
✔ RTL Design (synthesizable)
✔ Functional Verification

Backend stages such as synthesis, DFT, and physical design are out of scope, which is appropriate for an ASIC Design Verification-focused project.
