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

# Sail models and C emulators of Guru designs. Guru is only read: every generated file goes
# to build/<design name>/.
#
#   make                          Sail models and emulators of the Guru examples
#   make DESIGNS=../cheriot/      ... of other design directories (each with a Compile.hs)
#   make check                    compare emulator output with the Verilator simulators
#   make GURU_DIR=<path>          Guru checkout to use (default ../Guru)
#   make IO=<file.c>              harness with its own guru_send and guru_recv (default GuruIo.c)

GURU_DIR ?= ../Guru

# Sets GURU_DIR to an absolute path; provides gallina_used, gallina_lib and GALLINA_HSINC
include $(GURU_DIR)/Gallina.mk

DESIGNS ?= $(wildcard $(GURU_DIR)/Example/*/)

SAIL ?= sail
SAIL_LIB := $(shell $(SAIL) --dir)/lib
SAIL_RTS := $(addprefix $(SAIL_LIB)/,sail.c rts.c elf.c sail_failure.c sail_config.c cJSON.c)
GMP_FLAGS := $(shell pkg-config --cflags --libs gmp 2>/dev/null || echo -lgmp)

HASKELLS := Sail.hs SailPrinter.hs $(wildcard $(GURU_DIR)/PrettyPrinter/*.hs)
# The file with guru_send and guru_recv; a harness passes its own
IO ?= GuruIo.c

RUNTIME := GuruRuntime.c GuruRuntime.h GallinaShim.c $(IO)
FIXLITS := build/tools/FixLits

# Extra compiler arguments of an emulator whose Model.sail ($(2)) has Gallina calls; $(1) is
# its build directory, holding libgallina.a. Sail's elf.c and the GHC runtime both define
# lookupSymbol, so the one of Sail is renamed.
sail_gallina_args = $(if $(call gallina_used,$(1),$(2)),-DlookupSymbol=sail_elf_lookupSymbol GallinaShim.c -I$(GALLINA_HSINC) $(abspath $(1))/libgallina.a -liconv -lffi)

.PHONY: all models check clean
.DEFAULT_GOAL = all

$(FIXLITS): $(GURU_DIR)/PrettyPrinter/FixLits.hs
	mkdir -p build/tools
	ghc --make -package text $< -outputdir build/tools -o $@

# $(1) = design directory (with a trailing /), $(2) = its name
define Sail_rule
$(1)Compile.hs:
	@echo "$(1)Compile.hs is missing: extract it first (for the Guru examples: make -C $(GURU_DIR) coq)"
	@false

# A copy of the extracted module, with the fix-ups of Guru's Main_rule
build/$(2)/Compile.hs: $(1)Compile.hs $(FIXLITS)
	mkdir -p build/$(2)
	cp $(1)Compile.hs $$@
	grep -q "import qualified Data" $$@ || $(FIXLITS) $$@
	grep -q "import qualified Data" $$@ || sed -i "/import qualified Prelude/aimport qualified Data.Bits\nimport qualified Data.Char" $$@

build/$(2)/SailGen: build/$(2)/Compile.hs $(HASKELLS)
	ghc --make -j -i. -i$(GURU_DIR)/PrettyPrinter -ibuild/$(2) -main-is Sail Sail.hs -odir build/$(2) -hidir build/$(2) -o $$@

build/$(2)/Model.sail: build/$(2)/SailGen
	build/$(2)/SailGen > $$@

build/$(2)/model.c: build/$(2)/Model.sail GuruLibrary.sail
	$(SAIL) -c --c-include GuruRuntime.h GuruLibrary.sail build/$(2)/Model.sail -o build/$(2)/model

build/$(2)/sail_emu: build/$(2)/model.c $(RUNTIME)
	$$(call gallina_lib,build/$(2)/,build/$(2)/Model.sail)
	$(CC) -O2 -I. -I$(SAIL_LIB) build/$(2)/model.c $(SAIL_RTS) GuruRuntime.c $(IO) $$(call sail_gallina_args,build/$(2)/,build/$(2)/Model.sail) $(GMP_FLAGS) -lz -o $$@

# Same display output as the Verilator simulator of the design, with every CallGallina
# oracle set to zero on both sides
check-$(2): build/$(2)/sail_emu
	@test -x $(1)sim_obj_dir/Vtb || { echo "$(1)sim_obj_dir/Vtb is missing: build the Verilator simulator first"; false; }
	$(1)sim_obj_dir/Vtb +gallina_oracle_zero | grep -v '^- ' > build/$(2)/verilog.out || true
	GURU_GALLINA_ORACLE_ZERO=1 build/$(2)/sail_emu > build/$(2)/sail.out
	diff build/$(2)/verilog.out build/$(2)/sail.out
	@echo "$(2): Sail emulator and Verilator simulator print the same ($$$$(wc -l < build/$(2)/sail.out) lines)"

.PHONY: check-$(2)
endef

NAMES := $(foreach dir,$(DESIGNS),$(notdir $(patsubst %/,%,$(dir))))

$(foreach dir,$(DESIGNS),$(eval $(call Sail_rule,$(dir),$(notdir $(patsubst %/,%,$(dir))))))

models: $(patsubst %,build/%/Model.sail,$(NAMES))
all: $(patsubst %,build/%/sail_emu,$(NAMES))
check: $(patsubst %,check-%,$(NAMES))

clean:
	rm -rf build sail_smt_cache
