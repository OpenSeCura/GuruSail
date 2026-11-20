<!--
Copyright 2026 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# GuruSail

A Sail backend for [Guru](https://github.com/Cherified/Guru). It prints the compiled module
of a Guru design as a Sail model and builds a C emulator from it with Sail's C backend. It is
the Sail counterpart of the simulation Verilog that Guru prints (`Rtl s`, `SimRtl.sv`), and
is meant for plain simulation.

Guru is used read-only, from a sibling checkout (`../Guru` by default). Nothing is written
there: every generated file goes to `build/<design name>/`.

## Requirements

- A Guru checkout with the designs extracted (`make -C ../Guru coq` gives each example its
  `Compile.hs`). Tested against Guru commit `9a97e5d`.
- `ghc`, as for Guru's own printers.
- Sail (`opam install sail`; tested with 0.20.3) and `z3`, which Sail's type checker runs.
- A C compiler, GMP and zlib for the emulator.
- Only for `make check`: the Verilator simulators of the designs
  (`make -C ../Guru simrtlexe`).

## Usage

```
make                       # build/<name>/Model.sail and build/<name>/sail_emu for the Guru examples
make models                # only the Sail models
make check                 # compare each emulator's output with the Verilator simulator
make DESIGNS=../cheriot/   # other design directories; each must hold a Compile.hs
make GURU_DIR=<path>       # another Guru checkout
build/Test/sail_emu        # run an emulator
```

Per design the build copies `Compile.hs` to `build/<name>/` (with the same fix-ups as Guru's
`Main_rule`), compiles the generator `SailGen` from `Sail.hs`, prints `Model.sail`, runs
`sail -c` on `GuruLibrary.sail` and `Model.sail`, and compiles the result with Sail's C
runtime and `GuruRuntime.c`.

The emulator runs `step` for 100 cycles, or until the design calls `Finish`. That is the
number of cycles the Verilog testbench runs after reset. Environment variables:

| Variable | Meaning |
|---|---|
| `GURU_CYCLES=N` | cycles to run (default 100) |
| `GURU_SEED=N` | seed of `NonDet` values (default 0) |
| `GURU_TRACE_IO=1` | print every send and receive to stderr |
| `GURU_GALLINA_SEED=N` | seed of the `CallGallina` oracles (default 0), as `+gallina_seed=N` |
| `GURU_GALLINA_ORACLE_ZERO=1` | every oracle is `fun _ => 0`, as `+gallina_oracle_zero` |

## Files

| File | Contents |
|---|---|
| `Sail.hs` | main of the generator (`-main-is Sail`); the same name checks as Guru's `Rtl.hs` |
| `SailPrinter.hs` | kinds, constants, expressions and compiled code to Sail |
| `GuruLibrary.sail` | extern declarations and the helpers for operator edge cases |
| `GuruRuntime.c`, `GuruRuntime.h` | display, `NonDet` and the cycle limit |
| `GuruIo.c` | default method calls: a receive returns zero, a send is dropped; `make IO=<file.c>` uses a harness's own |
| `GallinaShim.c` | `CallGallina`, forwarded to Guru's `PrettyPrinter/GallinaRuntime.hs` |
| `Makefile` | the build described above |

`CodePrinter`, `ModPrinter`, `Rtl` and `GallinaRuntime` are used from
`$(GURU_DIR)/PrettyPrinter`, and `Gallina.mk` from `$(GURU_DIR)`. They are not copied.

## The model

The model has the shape of the simulation Verilog, with the same names:

- `register reg_<name>` for each register, initialised to its reset value, or to the default
  value when it has none.
- `register memRam_<name>` and `register memRp_<name>` for each memory: the contents and the
  values of its read ports. A read request stores the addressed element (the default value
  when the address is out of range) in the read port; a write to an out-of-range address
  does nothing.
- `function Send_<name>(v)` and `function Recv_<name>()` for each method. They call
  `guru_send("Send_<name>", bits)` and `guru_recv("Recv_<name>", width)` of the runtime, so
  the runtime sees every call in program order. The default runtime returns zero from a
  receive and drops a send, like the `sim_io` class of the Verilog; a harness replaces these
  two C functions.
- `function step()`, one clock cycle: every temporary `let_<name>_<index>` is a `var` set to
  zero, followed by the compiled code in order. Registers are read and written in place, so
  a read after a write in the same cycle sees the new value.
- `register guru_cycle` counts cycles, and `Finish` sets `register guru_finished`. As in
  Verilog, the rest of the cycle still runs.
- `function main()` runs `step` until the cycle limit or `guru_finished`.

A statement is printed exactly when the Verilog printer prints it. In particular, reads,
writes and assignments of zero-size kinds are skipped, and a zero-size temporary is printed
as its only value where an expression uses it.

### Kinds

| Guru kind | Sail |
|---|---|
| `Bool` | `bool` |
| `Bit n` | `bits(n)` |
| `Array n k` | `vector(n, T)` |
| `Struct ls` | `struct S_<i>`, with the fields of `ls` |
| `TaggedUnion ls` | `struct U_<i> = { data : bits(D), tag : bits(L) }` |
| `Struct []`, `Array 0 k` | `unit` |

Structs and tagged unions are numbered in order of first use, innermost first; the same
shape always gets the same name. `D` is the largest field size and `L` is
`log2_up (length ls)`. A tagged union is not a Sail `union`, because `ReadUnionData`
reinterprets the data bits whatever the tag is. A field whose name is a Sail keyword or
built-in type name gets a `_` suffix (the table is `sailReserved` in `SailPrinter.hs`).

Each struct, tagged union and array kind gets `to_bits_<name>` and `from_bits_<name>`
(arrays are named `A_<i>` for this purpose). The bit layout is that of `evalToBit` and of
the packed Verilog types: the first struct field is most significant, array element 0 is
least significant, and a tagged union is `{data, tag}` with the data most significant.

### Expressions

Expressions follow `evalExpr` in `Guru/Semantics.v`.

| Guru | Sail | Notes |
|---|---|---|
| `Or`, `And`, `Xor`, `Not` | `or_vec`, `and_vec`, `xor_vec`, `not_vec`; the `bool` versions on `Bool` | on structs, tagged unions and arrays through `to_bits`/`from_bits`; an empty list gives all zeros (all ones for `And`) |
| `Add`, `Mul` | `add_bits`, `guru_mul` | modulo 2^n; an empty list gives 0 and 1 |
| `Div`, `Rem` | `guru_udiv`, `guru_urem` | unsigned; dividing by zero gives all ones, and the remainder by zero is the dividend |
| `Sll`, `Srl`, `Sra` | `guru_sll`, `guru_srl`, `guru_sra` | shifting by the width or more gives zero, or all sign bits for `Sra` |
| `TruncLsb msb lsb`, `TruncMsb msb lsb` | `slice(v, 0, lsb)`, `slice(v, lsb, msb)` | |
| `Concat a b` | `bitvector_concat(a, b)` | `a` is most significant |
| `UXor`, `Ult`, `Eq` | `guru_uxor`, `guru_ult`, `eq_bits` on the bit encoding | |
| `ReadArray`, `UpdateArray` | `guru_read_array`, `guru_update_array` | reading out of range gives the default value; updating out of range changes nothing |
| `ReadArrayConst`, `UpdateArrayConst` | `v[i]`, `[v with i = x]` | |
| `ReadStruct`, `UpdateStruct`, `BuildStruct` | `x.f`, `{ x with f = v }`, `struct { ... }` | |
| `ReadUnionTag i` | `x.tag == i` | `true` when the tag has no bits |
| `ReadUnionData i` | `from_bits` of the low bits of `x.data` | |
| `BuildUnion i e` | `struct { data = zero-extended to_bits(e), tag = i }` | |
| `ToBit`, `FromBit` | `to_bits_<name>`, `from_bits_<name>` | |

### System calls, NonDet and CallGallina

- `DispString` and `DispExpr` print through `guru_write_str` and `guru_write_bits`, which
  format a value under `%<0?><width><b|d|x>` as Verilator does: without leading zeros,
  padded to the width with zeros, or with spaces for decimal without the `0` flag.
- `NonDet` is `guru_nondet(width)`, a seeded pseudo-random value.
- `CallGallina` is `guru_gallina_call(site, leaf, guru_cycle, W, input bits, output width)`.
  `GallinaShim.c` forwards it to `hs_guru_gallina_call` of Guru's `GallinaRuntime.hs`, which
  is linked in as a static library (built with `gallina_lib` of `Gallina.mk`) only when the
  model has such calls. The Gallina registers live in that Haskell runtime, as they do for
  the Verilator simulator.

## Checked against the Verilog simulation

`make check` runs each emulator and the Verilator simulator of the same design and compares
what they print. With Guru `9a97e5d`:

| Example | Result |
|---|---|
| Test | the same 100 lines |
| Gallina | the same 10 lines, with zero oracles and with a seed (`GURU_GALLINA_SEED=7` against `+gallina_seed=7`) |
| Fifo, SimpleProcessor | type-check, build and run; neither prints anything on either side |

## CHERIoT specifications

`cheriot/` holds a harness for the CHERIoT specifications of `../cheriot` and
`../SpecCheriot`:

| File | Contents |
|---|---|
| `cheriot/CheriotIo.c` | external RAM, revocation table, UART and the tohost check; a C port of `cheriot/TbCommon.sv`, used in place of `GuruIo.c` |
| `cheriot/run_tests.sh` | runs the binaries of `../basic-riscv-tests-cheriot` on an emulator |
| `cheriot/NondetStep/NondetStepInst.v` | a module with only `nondetSpecStep`; only its `Model.sail` has been generated |

```
make DESIGNS=../SpecCheriot/NondetSim/ IO=cheriot/CheriotIo.c    # needs NondetSim/Compile.hs
cheriot/run_tests.sh build/NondetSim/sail_emu
```

With SpecCheriot `db0bf54`, the emulator of `nondetSpec` passes all 50 tests, for
`GURU_SEED` 0, 1 and 12345 (the seed of the don't-care values). The Verilator simulator of
the same module passes the same 50; the cycle count each side prints at the end of a test
differs by exactly one in every test (the emulator's is one lower).

## Sail's type checker

Sail 0.20.3 takes exponential time to type-check nested calls of `and_bool`, `or_bool` and
`not_bool`, whose types carry the value of the result. The model uses `guru_and`, `guru_or`
and `guru_not` on plain `bool` instead. With that, `sail -c` on the 1.3 MB model of
`nondetSpec` takes about 17 s the first time and 3 s once Sail has cached its solver
results; compiling the generated C takes about 9 s.

A Guru `Concat` is printed with its result width, `(bitvector_concat(a, b) : bits(n))`, so
that Sail checks the width rather than solving for it.

## Known gaps

- Only display output is compared. Fifo and SimpleProcessor print nothing, so for them the
  check shows only that the model type-checks and runs.
- `NonDet` values differ from Verilator's `$urandom`, so a design whose output depends on
  them prints different values.
- Without a `gallina_seed` plusarg the Verilator shim takes Verilator's own seed, while the
  emulator defaults to 0. Set the seed or the zero oracle on both sides to compare.
- A register without a reset value starts at the default value, as in `InitStateElem`. The
  simulation Verilog leaves it uninitialised.
- Division by zero follows `evalExpr`, as listed above. The Verilog `/` and `%` give
  Verilator's result there, so the two can differ.
- The text of a `DispString` is passed on as it is, as the Verilog printer does: `\n` in it
  is a line break. A `%` in it is printed literally, while Verilog's `$write` reads it as a
  format.
- There is no `reset` function: the initial values are in the register declarations.
- The model is written for Sail's C backend. Its other backends (`-coq`, `-lean`) have not
  been tried.

## Use of AI

AI was used to generate the Sail pretty printer for Guru, written in Haskell, and humans
reviewed it. The reviewers are not familiar with Sail's syntax, and do not know whether Sail
has surprising semantics of the kind SystemVerilog has (see
https://github.com/Cherified/Guru/commit/9a97e5d8624ac65524fc50e61789aeed53572461).

Both `specModInst` of https://github.com/OpenSeCura/cheriot and `simpleSpecModInst` of
https://github.com/OpenSeCura/SpecCheriot were tested, and their outputs (the UART output and
the cycle counts) matched those of the Verilator simulators exactly.
