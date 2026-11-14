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

/* Helpers for Sail models printed by GuruSail. The edge cases follow evalExpr in
 * Guru/Semantics.v (Zmod.udiv, Zmod.umod, Zmod.slu, Zmod.sru, Zmod.srs). */

default Order dec
$include <prelude.sail>

/* ---- Implemented by the C runtime (GuruRuntime.c, GallinaShim.c) ---- */

/* Display: text, and a value under a Verilog format %<0?><width><b|d|x> */
val guru_write_str = impure {c: "guru_write_str"} : string -> unit
val guru_write_bits = impure {c: "guru_write_bits"} : forall 'n, 'n >= 0. (string, bits('n)) -> unit

/* Method calls, by method name and in program order */
val guru_send = impure {c: "guru_send"} : forall 'n, 'n >= 0. (string, bits('n)) -> unit
val guru_recv = impure {c: "guru_recv"} : forall 'n, 'n >= 0. (string, int('n)) -> bits('n)

/* NonDet */
val guru_nondet = impure {c: "guru_nondet"} : forall 'n, 'n >= 0. int('n) -> bits('n)

/* Number of cycles main runs unless the design finishes earlier */
val guru_max_cycles = impure {c: "guru_max_cycles"} : unit -> int

/* CallGallina: (call site, Gallina register leaf, cycle, width of the runtime's bit vectors,
 * input bits, output width) */
val guru_gallina_call = impure {c: "guru_gallina_call"} :
  forall 'n 'm, 'n >= 0 & 'm >= 0. (int, int, int, int, bits('n), int('m)) -> bits('m)

/* ---- Conversions ---- */

val guru_bool_to_bits : bool -> bits(1)
function guru_bool_to_bits(b) = if b then 0b1 else 0b0

val guru_bits_to_bool : bits(1) -> bool
function guru_bits_to_bool(b) = b == 0b1

val guru_drop : forall 'n, 'n >= 0. bits('n) -> unit
function guru_drop(_) = ()

/* ---- Operators ---- */

/* and, or and not on plain bool. Sail's and_bool, or_bool and not_bool carry the value of the
 * result in its type, and its type checker takes exponential time on nested calls of them. */
val guru_and : (bool, bool) -> bool
function guru_and(a, b) = if a then b else false

val guru_or : (bool, bool) -> bool
function guru_or(a, b) = if a then true else b

val guru_not : bool -> bool
function guru_not(a) = if a then false else true

val guru_xor_bool : (bool, bool) -> bool
function guru_xor_bool(a, b) = if a then not_bool(b) else b

/* xor of all bits */
val guru_uxor : forall 'n, 'n >= 0. bits('n) -> bool
function guru_uxor(v) = {
  var r : bool = false;
  foreach (i from 0 to ('n - 1)) {
    if v[i] == bitone then r = not_bool(r)
  };
  r
}

val guru_ult : forall 'n, 'n >= 0. (bits('n), bits('n)) -> bool
function guru_ult(a, b) = unsigned(a) < unsigned(b)

/* product modulo 2 ^ n */
val guru_mul : forall 'n, 'n >= 0. (bits('n), bits('n)) -> bits('n)
function guru_mul(a, b) = get_slice_int('n, unsigned(a) * unsigned(b), 0)

/* unsigned division; dividing by zero gives all ones */
val guru_udiv : forall 'n, 'n >= 0. (bits('n), bits('n)) -> bits('n)
function guru_udiv(a, b) =
  if unsigned(b) == 0 then sail_ones('n)
  else get_slice_int('n, tdiv_int(unsigned(a), unsigned(b)), 0)

/* unsigned remainder; the remainder by zero is the dividend */
val guru_urem : forall 'n, 'n >= 0. (bits('n), bits('n)) -> bits('n)
function guru_urem(a, b) =
  if unsigned(b) == 0 then a
  else get_slice_int('n, tmod_int(unsigned(a), unsigned(b)), 0)

/* shifts; shifting by the width or more gives zero, or all sign bits for guru_sra */
val guru_sll : forall 'n 'm, 'n >= 0 & 'm >= 0. (bits('n), bits('m)) -> bits('n)
function guru_sll(a, b) = {
  let s = unsigned(b);
  if s >= 'n then sail_zeros('n) else sail_shiftleft(a, s)
}

val guru_srl : forall 'n 'm, 'n >= 0 & 'm >= 0. (bits('n), bits('m)) -> bits('n)
function guru_srl(a, b) = {
  let s = unsigned(b);
  if s >= 'n then sail_zeros('n) else sail_shiftright(a, s)
}

val guru_sra : forall 'n 'm, 'n > 0 & 'm >= 0. (bits('n), bits('m)) -> bits('n)
function guru_sra(a, b) = {
  let s = unsigned(b);
  if s >= 'n then (if a['n - 1] == bitone then sail_ones('n) else sail_zeros('n))
  else sail_arith_shiftright(a, s)
}

/* ---- Arrays ---- */

/* reading out of range gives the default d */
val guru_read_array : forall 'n 'm ('a : Type), 'n >= 0 & 'm >= 0. (vector('n, 'a), bits('m), 'a) -> 'a
function guru_read_array(v, i, d) = {
  let idx = unsigned(i);
  if idx < 'n then v[idx] else d
}

/* updating out of range changes nothing */
val guru_update_array : forall 'n 'm ('a : Type), 'n >= 0 & 'm >= 0. (vector('n, 'a), bits('m), 'a) -> vector('n, 'a)
function guru_update_array(v, i, x) = {
  let idx = unsigned(i);
  if idx < 'n then [v with idx = x] else v
}
