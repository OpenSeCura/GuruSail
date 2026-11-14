(*
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
 *)

(* A module with only the core step of nondetSpec (SpecCheriot/NondetSpec.v), on the concrete
 * system of cheriot/SpecInst.v, compiled for the Sail backend. The other steps of nondetSpec
 * (revoker, PLIC, CLINT, second line, fence.i acknowledgement) are left out. *)

From Stdlib Require Import String List ZArith.
From Guru Require Import Primitives Library Syntax Combinators Notations.
From Cheriot Require Import SpecDefines SpecDevice Clint SpecRevoker Plic SpecInst.
From SpecCheriot Require Import Spec NondetSpec.

Import ListNotations.

Definition nondetStepModInst : Mod specSysTreeInst :=
  fun ty =>
    [ @nondetSpecStep PcAddrInit concreteRevConfig concreteRegions concreteClint concretePlic ty ].

From Guru Require Import Extraction Compiler.
Set Extraction Output Directory "cheriot/NondetStep".

Definition compiledMod := compile nondetStepModInst.
Extraction "Compile" kindSize Z.log2_up getDefault isEq compiledMod.
