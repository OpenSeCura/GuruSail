/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* C side of the externs declared in GuruLibrary.sail, in the calling convention of Sail's
 * C backend: bit vectors of any width are lbits, integers are sail_int, and a result that
 * is not a machine value comes back through a first pointer argument. */

#ifndef GURU_RUNTIME_H
#define GURU_RUNTIME_H

#include "sail.h"

unit guru_write_str(const_sail_string s);
unit guru_write_bits(const_sail_string fmt, const lbits v);

unit guru_send(const_sail_string name, const lbits v);
void guru_recv(lbits *out, const_sail_string name, const sail_int width);

void guru_nondet(lbits *out, const sail_int width);

void guru_max_cycles(sail_int *out, const unit u);

/* GallinaShim.c; linked only into models that use CallGallina */
void guru_gallina_call(lbits *out, const sail_int site, const sail_int leaf, const sail_int cycle,
                       const sail_int width, const lbits in, const sail_int out_width);

#endif
