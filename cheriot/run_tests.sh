#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Runs the tests of basic-riscv-tests-cheriot on a GuruSail emulator built with
# IO=cheriot/CheriotIo.c, as cheriot/run_all_tests.sh does on a Verilator simulator.
#
#   cheriot/run_tests.sh <emulator> [<elf> ...]
#
# Without ELF files it runs every binary of ../basic-riscv-tests-cheriot/binaries.
# Environment: LLVM_DIR (llvm-objdump, llvm-objcopy), JOBS (tests in parallel, default 8),
# MAX_CYCLES (default 50000000), OUT_DIR (logs, default <emulator dir>/tests).

HERE=$(cd "$(dirname "$0")" && pwd)
LLVM_DIR="${LLVM_DIR:-$HOME/work/Cheriot/llvm-project/builds/cheriot-llvm}"
JOBS="${JOBS:-8}"
MAX_CYCLES="${MAX_CYCLES:-50000000}"

# One test: prints "PASS|FAIL <name> <cycles>"
if [ "$1" = "--one" ]; then
    emu="$2"; elf="$3"; out="$4"
    name=$(basename "$elf" .elf)
    tohost=$("$LLVM_DIR/bin/llvm-objdump" -t "$elf" | awk '$NF == "tohost" {print $1}')
    "$LLVM_DIR/bin/llvm-objcopy" -O binary "$elf" "$out/$name.bin"
    hexdump -v -e '1/8 "%016x\n"' "$out/$name.bin" > "$out/$name.hex"
    if CHERIOT_BIN="$out/$name.hex" CHERIOT_TOHOST="$tohost" GURU_CYCLES="$MAX_CYCLES" "$emu" > "$out/$name.log" 2>&1 \
       && grep -q "TEST PASSED" "$out/$name.log"; then
        result=PASS
    else
        result=FAIL
    fi
    cycles=$(sed -n 's/^\[Cycle \([0-9]*\)\] Final cycle count$/\1/p' "$out/$name.log")
    rm -f "$out/$name.bin" "$out/$name.hex"
    echo "$result $name ${cycles:--}"
    exit 0
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 <emulator> [<elf> ...]"
    exit 1
fi

EMU=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
shift
OUT_DIR="${OUT_DIR:-$(dirname "$EMU")/tests}"
mkdir -p "$OUT_DIR"

if [ $# -eq 0 ]; then
    set -- "$HERE"/../../basic-riscv-tests-cheriot/binaries/*.elf
fi

printf '%s\n' "$@" | xargs -P "$JOBS" -I{} "$0" --one "$EMU" {} "$OUT_DIR" | sort -k2 > "$OUT_DIR/summary.txt"

cat "$OUT_DIR/summary.txt"
total=$(wc -l < "$OUT_DIR/summary.txt" | tr -d ' ')
passed=$(grep -c '^PASS' "$OUT_DIR/summary.txt")
echo ""
echo "Summary: $passed/$total tests passed."
[ "$passed" = "$total" ]
