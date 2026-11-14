{-
 - Copyright 2026 Google LLC
 -
 - Licensed under the Apache License, Version 2.0 (the "License");
 - you may not use this file except in compliance with the License.
 - You may obtain a copy of the License at
 -
 -     https://www.apache.org/licenses/LICENSE-2.0
 -
 - Unless required by applicable law or agreed to in writing, software
 - distributed under the License is distributed on an "AS IS" BASIS,
 - WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 - See the License for the specific language governing permissions and
 - limitations under the License.
 -}

-- Prints a Guru CompiledModule as a Sail model. It follows the simulation Verilog
-- printed by Guru's PrettyPrinter (Rtl s): same element and temporary names, the same
-- statements skipped for zero-size kinds, registers updated in program order.

module SailPrinter (ppSailTop) where

import Data.Char (intToDigit)
import Data.List (intercalate, genericIndex, genericLength, nubBy)
import qualified Data.Map.Strict as M
import Numeric (showHex, showIntAtBase)
import Compile
  ( Kind(..), Expr(..), Compiled(..), SysT(..), Elem(..), Reg(..), Mem(..)
  , CExpr, CompiledModule, Any, unsafeCoerce, kindSize, log2_up )
import CodePrinter
  ( tag, ppTmp, ppReg, ppMem, ppMeth, ppFullFormat, ppIndent, deformat, gallinaCalls, gallinaWidth )
import ModPrinter (filteredElems)

-- ---------------------------------------------------------------------------------
-- Kinds

type Fields = [(String, Kind)]

-- Kinds with a single value and no fields or elements are printed as unit.
isUnit :: Kind -> Bool
isUnit (Struct []) = True
isUnit (Array n _) = n <= 0
isUnit _ = False

unionDataSize :: Fields -> Integer
unionDataSize ls = maximum (0 : map (kindSize . snd) ls)

unionTagSize :: Fields -> Integer
unionTagSize ls = log2_up (genericLength ls)

kindKey :: Kind -> String
kindKey Bool = "B"
kindKey (Bit n) = "b" ++ show n
kindKey (Struct ls) = "S{" ++ concatMap (\(s, k) -> s ++ ":" ++ kindKey k ++ ";") ls ++ "}"
kindKey (TaggedUnion ls) = "U{" ++ concatMap (\(s, k) -> s ++ ":" ++ kindKey k ++ ";") ls ++ "}"
kindKey (Array n k) = "A" ++ show n ++ "[" ++ kindKey k ++ "]"

-- The struct, union and array kinds inside a kind, innermost first.
postKinds :: Kind -> [Kind]
postKinds k | isUnit k = []
postKinds k@(Struct ls) = concatMap (postKinds . snd) ls ++ [k]
postKinds k@(TaggedUnion ls) = concatMap (postKinds . snd) ls ++ [k]
postKinds k@(Array _ k') = postKinds k' ++ [k]
postKinds _ = []

-- Canonical kind string -> hoisted name (S_n struct, U_n tagged union, A_n array helpers)
type Env = M.Map String String

nameOf :: Env -> Kind -> String
nameOf env k = M.findWithDefault (error ("SailPrinter: kind was not hoisted: " ++ kindKey k)) (kindKey k) env

numberKinds :: [Kind] -> [(Kind, String)]
numberKinds ks =
  let distinct = nubBy (\a b -> kindKey a == kindKey b) (concatMap postKinds ks)
      prefix (Struct _) = "S_"
      prefix (TaggedUnion _) = "U_"
      prefix _ = "A_"
  in [(k, prefix k ++ show i) | (i, k) <- zip [(1 :: Integer) ..] distinct]

-- Sail keywords and built-in type names; a field with one of these names gets a '_' suffix.
sailReserved :: [String]
sailReserved =
  [ "and", "as", "assert", "atom", "backwards", "bit", "bitfield", "bitone", "bits", "bitzero"
  , "bool", "by", "cast", "catch", "clause", "configuration", "constant", "constraint", "dec"
  , "default", "do", "downto", "effect", "else", "end", "enum", "exit", "false", "forall"
  , "foreach", "forwards", "from", "function", "if", "impl", "implicit", "impure", "in", "inc"
  , "infix", "infixl", "infixr", "instantiation", "int", "let", "list", "mapping", "match"
  , "monadic", "mutual", "nat", "newtype", "operator", "option", "outcome", "overload"
  , "private", "public", "pure", "range", "real", "ref", "register", "repeat", "return"
  , "scattered", "sizeof", "string", "struct", "termination_measure", "then", "throw", "to"
  , "true", "try", "type", "typedef", "undefined", "union", "unit", "until", "val", "var"
  , "vector", "while", "with", "Bool", "Int", "Order", "Type" ]

field :: String -> String
field s = if s `elem` sailReserved then s ++ "_" else s

ty :: Env -> Kind -> String
ty _ Bool = "bool"
ty _ (Bit n) = "bits(" ++ show n ++ ")"
ty env k
  | isUnit k = "unit"
  | Array n k' <- k = "vector(" ++ show n ++ ", " ++ ty env k' ++ ")"
  | otherwise = nameOf env k

call :: String -> [String] -> String
call f args = f ++ "(" ++ intercalate ", " args ++ ")"

-- Bit encoding of a value, as in evalToBit: first struct field most significant, array
-- element 0 least significant, tagged union {data, tag} with data most significant.
toBits :: Env -> Kind -> String -> String
toBits _ Bool s = call "guru_bool_to_bits" [s]
toBits _ (Bit _) s = s
toBits env k s
  | isUnit k = "sail_zeros(0)"
  | otherwise = call ("to_bits_" ++ nameOf env k) [s]

fromBits :: Env -> Kind -> String -> String
fromBits _ Bool s = call "guru_bits_to_bool" [s]
fromBits _ (Bit _) s = s
fromBits env k s
  | isUnit k = "()"
  | otherwise = call ("from_bits_" ++ nameOf env k) [s]

zero :: Env -> Kind -> String
zero _ Bool = "false"
zero env k = fromBits env k (call "sail_zeros" [show (kindSize k)])

ones :: Env -> Kind -> String
ones _ Bool = "true"
ones env k = fromBits env k (call "sail_ones" [show (kindSize k)])

-- Bit vector literal of exactly n bits
bitLit :: Integer -> Integer -> String
bitLit n v
  | n <= 0 = "sail_zeros(0)"
  | n `mod` 4 == 0 = "0x" ++ pad (n `div` 4) (showHex v' "")
  | otherwise = "0b" ++ pad n (showIntAtBase 2 intToDigit v' "")
  where
    v' = v `mod` (2 ^ n)
    pad w s = replicate (fromInteger w - length s) '0' ++ s

slice :: String -> Integer -> Integer -> String
slice s start len = call "slice" [s, show start, show len]

-- Concatenation of bit vectors, most significant first
concatBits :: [String] -> String
concatBits [] = "sail_zeros(0)"
concatBits ss = foldr1 (\a b -> call "bitvector_concat" [a, b]) ss

structLit :: String -> [(String, String)] -> String
structLit name fs = "(struct { " ++ intercalate ", " [f ++ " = " ++ v | (f, v) <- fs] ++ " } : " ++ name ++ ")"

-- Declaration of a hoisted kind, with its to_bits and from_bits functions
ppKindDecl :: Env -> (Kind, String) -> String
ppKindDecl env (k, name) =
  let size = kindSize k
      t = ty env k
      conv toBody fromBody =
        "function to_bits_" ++ name ++ "(x : " ++ t ++ ") -> bits(" ++ show size ++ ") = " ++ toBody ++ "\n"
        ++ "function from_bits_" ++ name ++ "(b : bits(" ++ show size ++ ")) -> " ++ t ++ " = " ++ fromBody ++ "\n\n"
  in case k of
       Struct ls ->
         let offsets = drop 1 (scanr (\(_, fk) acc -> acc + kindSize fk) 0 ls)
         in "struct " ++ name ++ " = { " ++ intercalate ", " [field s ++ " : " ++ ty env fk | (s, fk) <- ls] ++ " }\n"
            ++ conv (concatBits [toBits env fk ("x." ++ field s) | (s, fk) <- ls])
                    (structLit name [(field s, fromBits env fk (slice "b" lo (kindSize fk))) | ((s, fk), lo) <- zip ls offsets])
       TaggedUnion ls ->
         let d = unionDataSize ls
             l = unionTagSize ls
         in "/* tagged union; tags: " ++ intercalate ", " [show i ++ " = " ++ s | (i, (s, _)) <- tag ls] ++ " */\n"
            ++ "struct " ++ name ++ " = { data : bits(" ++ show d ++ "), tag : bits(" ++ show l ++ ") }\n"
            ++ conv (concatBits ["x.data", "x.tag"])
                    (structLit name [("data", slice "b" l d), ("tag", slice "b" 0 l)])
       Array n k' ->
         let w = kindSize k'
             idxs = reverse [0 .. n - 1]
         in conv (concatBits [toBits env k' ("x[" ++ show i ++ "]") | i <- idxs])
                 ("[" ++ intercalate ", " [fromBits env k' (slice "b" (i * w) w) | i <- idxs] ++ "]")
       _ -> ""

-- ---------------------------------------------------------------------------------
-- Constants (extracted values: Bool, Integer, nested pairs, lists; see CodePrinter.ppConst)

tupleToList :: [a] -> Any -> [Any]
tupleToList [] _ = []
tupleToList (_ : xs) v = let (a, b) = unsafeCoerce v :: (Any, Any) in a : tupleToList xs b

ppConst :: Env -> Kind -> Any -> String
ppConst _ Bool v = if (unsafeCoerce v :: Bool) then "true" else "false"
ppConst _ (Bit n) v = bitLit n (unsafeCoerce v :: Integer)
ppConst env k v
  | isUnit k = "()"
  | Struct ls <- k =
      structLit (nameOf env k) [(field s, ppConst env fk fv) | ((s, fk), fv) <- zip ls (tupleToList ls v)]
  | Array n k' <- k =
      "([" ++ intercalate ", " (reverse (map (ppConst env k') (unsafeCoerce v :: [Any]))) ++ "] : " ++ ty env k ++ ")"
  | TaggedUnion ls <- k =
      let (d, t) = unsafeCoerce v :: (Integer, Integer)
      in structLit (nameOf env k) [("data", bitLit (unionDataSize ls) d), ("tag", bitLit (unionTagSize ls) t)]

-- ---------------------------------------------------------------------------------
-- Expressions (ground truth: evalExpr in Guru/Semantics.v)

-- An expression that can be followed by .field or [index]
atom :: Env -> CExpr -> String
atom env e@(Var k _) | kindSize k > 0 = ppExpr env e
atom env e = "(" ++ ppExpr env e ++ ")"

-- Fold a binary function over the operands; fieldwise on structs and arrays, which is
-- bitwise on the bit encoding.
ppLogic :: Env -> String -> String -> String -> Kind -> [CExpr] -> String
ppLogic env _ _ identity _ [] = identity
ppLogic env boolF bitsF _ k ls = case k of
  Bool -> foldr1 (\a b -> call boolF [a, b]) (map (ppExpr env) ls)
  Bit _ -> foldr1 (\a b -> call bitsF [a, b]) (map (ppExpr env) ls)
  _ -> fromBits env k (foldr1 (\a b -> call bitsF [a, b]) (map (toBits env k . ppExpr env) ls))

ppExpr :: Env -> CExpr -> String
ppExpr env (Var k tmp) = if kindSize k > 0 then ppTmp tmp else zero env k
ppExpr env (Const k val) = ppConst env k val
ppExpr env (Or k ls) = ppLogic env "guru_or" "or_vec" (zero env k) k ls
ppExpr env (And k ls) = ppLogic env "guru_and" "and_vec" (ones env k) k ls
ppExpr env (Xor k ls) = ppLogic env "guru_xor_bool" "xor_vec" (zero env k) k ls
ppExpr env (Not k e) = case k of
  Bool -> call "guru_not" [ppExpr env e]
  Bit _ -> call "not_vec" [ppExpr env e]
  _ -> fromBits env k (call "not_vec" [toBits env k (ppExpr env e)])
ppExpr env (TruncLsb _ lsb e) = slice (ppExpr env e) 0 lsb
ppExpr env (TruncMsb msb lsb e) = slice (ppExpr env e) lsb msb
ppExpr env (UXor _ e) = call "guru_uxor" [ppExpr env e]
ppExpr env (Add n ls) = case ls of
  [] -> bitLit n 0
  _ -> foldr1 (\a b -> call "add_bits" [a, b]) (map (ppExpr env) ls)
ppExpr env (Mul n ls) = case ls of
  [] -> bitLit n 1
  _ -> foldr1 (\a b -> call "guru_mul" [a, b]) (map (ppExpr env) ls)
ppExpr env (Div _ a b) = call "guru_udiv" [ppExpr env a, ppExpr env b]
ppExpr env (Rem _ a b) = call "guru_urem" [ppExpr env a, ppExpr env b]
ppExpr env (Sll _ _ a b) = call "guru_sll" [ppExpr env a, ppExpr env b]
ppExpr env (Srl _ _ a b) = call "guru_srl" [ppExpr env a, ppExpr env b]
ppExpr env (Sra n _ a b) = if n <= 0 then ppExpr env a else call "guru_sra" [ppExpr env a, ppExpr env b]
ppExpr env (Concat n m a b) = "(" ++ call "bitvector_concat" [ppExpr env a, ppExpr env b] ++ " : bits(" ++ show (n + m) ++ "))"
ppExpr env (ITE _ p t f) = "(if " ++ ppExpr env p ++ " then " ++ ppExpr env t ++ " else " ++ ppExpr env f ++ ")"
ppExpr env (Eq0 k a b) = case k of
  Bool -> call "eq_bool" [ppExpr env a, ppExpr env b]
  _ -> call "eq_bits" [toBits env k (ppExpr env a), toBits env k (ppExpr env b)]
ppExpr env (Ult _ a b) = call "guru_ult" [ppExpr env a, ppExpr env b]
ppExpr env (ReadStruct ls e i) = atom env e ++ "." ++ field (fst (genericIndex ls i))
ppExpr env (ReadArray n _ k e i)
  | n <= 0 = zero env k
  | otherwise = call "guru_read_array" [ppExpr env e, ppExpr env i, zero env k]
ppExpr env (ReadArrayConst _ _ e i) = atom env e ++ "[" ++ show i ++ "]"
ppExpr env (UpdateStruct ls e p v) =
  "{ " ++ atom env e ++ " with " ++ field (fst (genericIndex ls p)) ++ " = " ++ ppExpr env v ++ " }"
ppExpr env (UpdateArray n _ e _ p v)
  | n <= 0 = ppExpr env e
  | otherwise = call "guru_update_array" [ppExpr env e, ppExpr env p, ppExpr env v]
ppExpr env (UpdateArrayConst _ _ e p v) = "[" ++ atom env e ++ " with " ++ show p ++ " = " ++ ppExpr env v ++ "]"
ppExpr env (ToBit k e) = toBits env k (ppExpr env e)
ppExpr env (FromBit k e) = fromBits env k (ppExpr env e)
ppExpr env (ReadUnionTag ls e i)
  | unionTagSize ls <= 0 = "true"
  | otherwise = call "eq_bits" [atom env e ++ ".tag", bitLit (unionTagSize ls) i]
ppExpr env (ReadUnionData ls e i) =
  let k = snd (genericIndex ls i)
  in fromBits env k (slice (atom env e ++ ".data") 0 (kindSize k))
ppExpr env (BuildUnion ls i e) =
  let k = snd (genericIndex ls i)
  in structLit (nameOf env (TaggedUnion ls))
       [ ("data", call "sail_zero_extend" [toBits env k (ppExpr env e), show (unionDataSize ls)])
       , ("tag", bitLit (unionTagSize ls) i) ]
ppExpr env (BuildStruct ls vals)
  | null ls = "()"
  | otherwise = structLit (nameOf env (Struct ls))
      [(field s, ppExpr env (unsafeCoerce v :: CExpr)) | ((s, _), v) <- zip ls (tupleToList ls vals)]
ppExpr env (BuildArray n k vals)
  | n <= 0 = "()"
  | otherwise = "([" ++ intercalate ", " (reverse (map (ppExpr env) vals)) ++ "] : " ++ ty env (Array n k) ++ ")"

-- ---------------------------------------------------------------------------------
-- System calls

sailString :: String -> String
sailString s = "\"" ++ concatMap esc s ++ "\""
  where
    esc '\n' = "\\n"
    esc '\t' = "\\t"
    esc '\r' = "\\r"
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc c = [c]

-- The printed values of a displayed expression, as bit vectors (see CodePrinter.ppCExprList)
dispLeaves :: Env -> Kind -> CExpr -> [String]
dispLeaves _ k _ | kindSize k <= 0 = []
dispLeaves env Bool e = [toBits env Bool (ppExpr env e)]
dispLeaves env (Bit _) e = [ppExpr env e]
dispLeaves env (Struct ls) e = concat [dispLeaves env k (ReadStruct ls e i) | (i, (_, k)) <- tag ls]
dispLeaves env (Array n k) e = concat [dispLeaves env k (ReadArrayConst n k e i) | i <- [0 .. n - 1]]
dispLeaves env k@(TaggedUnion ls) e
  | unionTagSize ls <= 0 || unionDataSize ls <= 0 = [toBits env k (ppExpr env e)]
  | otherwise = [atom env e ++ ".data", atom env e ++ ".tag"]

-- Splits a format string of ppFullFormat into text and %<0?><width><b|d|x> pieces
data FmtPiece = FmtText String | FmtSpec String

splitFormat :: String -> [FmtPiece]
splitFormat [] = []
splitFormat ('%' : rest) =
  let (spec, rest') = break (`elem` "bdx") rest
  in case rest' of
       (c : rest'') -> FmtSpec ('%' : spec ++ [c]) : splitFormat rest''
       [] -> error "SailPrinter: malformed display format"
splitFormat s = let (txt, rest) = break (== '%') s in FmtText txt : splitFormat rest

stmt :: Int -> String -> String
stmt q s = ppIndent q ++ s ++ ";\n"

ppSys :: Env -> Int -> SysT (String, Integer) -> String
-- The text is printed as in the Verilog $write: its escapes (such as \n) are kept as they are
ppSys _ q (DispString s) = stmt q (call "guru_write_str" ["\"" ++ deformat s ++ "\""])
ppSys env q (DispExpr k e f)
  | kindSize k <= 0 = ""
  | otherwise = go (splitFormat (ppFullFormat f)) (dispLeaves env k e)
  where
    go [] [] = ""
    go (FmtText t : ps) ls = stmt q (call "guru_write_str" [sailString t]) ++ go ps ls
    go (FmtSpec s : ps) (l : ls) = stmt q (call "guru_write_bits" [sailString s, l]) ++ go ps ls
    go _ _ = error "SailPrinter: display format and values do not match"
ppSys _ q Finish = stmt q "guru_finished = true"

-- ---------------------------------------------------------------------------------
-- Compiled code. A statement is printed exactly when CodePrinter.ppCompiled prints it.

ppBlock :: Int -> String -> String
ppBlock q body = "{\n" ++ (if null body then stmt (q + 1) "()" else body) ++ ppIndent q ++ "}"

ppCompiled :: Env -> Integer -> Int -> Compiled -> String
ppCompiled env gw q c = case c of
  CReadReg reg k tmp rest -> when (kindSize k > 0) [ppTmp tmp ++ " = " ++ ppReg reg] ++ next rest
  CWriteReg reg k val rest -> when (kindSize k > 0) [ppReg reg ++ " = " ++ ex val] ++ next rest
  CReadRqMem mem sz k ports i p rest ->
    when (isMem sz k ports)
      [ppMem "Rp" mem ++ "[" ++ show p ++ "] = " ++ call "guru_read_array" [ppMem "Ram" mem, ex i, zero env k]]
    ++ next rest
  CReadRpMem mem sz k ports p tmp rest ->
    when (isMem sz k ports) [ppTmp tmp ++ " = " ++ ppMem "Rp" mem ++ "[" ++ show p ++ "]"] ++ next rest
  CWriteMem mem sz k ports i val rest ->
    when (isMem sz k ports)
      ["{ let idx = unsigned(" ++ ex i ++ "); if idx < " ++ show sz ++ " then " ++ ppMem "Ram" mem ++ "[idx] = " ++ ex val ++ " }"]
    ++ next rest
  CSend meth _ e rest -> stmt q (call (ppMeth "Send" meth) [ex e]) ++ next rest
  CRecv meth k tmp rest -> when (kindSize k > 0) [ppTmp tmp ++ " = " ++ call (ppMeth "Recv" meth) []] ++ next rest
  CLetExpr tmp k e rest -> when (kindSize k > 0) [ppTmp tmp ++ " = " ++ ex e] ++ next rest
  CLetAction _ act rest -> stmt q (ppBlock q (ppCompiled env gw (q + 1) act)) ++ next rest
  CNonDet tmp k rest ->
    when (kindSize k > 0) [ppTmp tmp ++ " = " ++ fromBits env k (call "guru_nondet" [show (kindSize k)])] ++ next rest
  CIfElse p _ t f rest ->
    stmt q ("if " ++ ex p ++ " then " ++ ppBlock q (ppCompiled env gw (q + 1) t)
            ++ " else " ++ ppBlock q (ppCompiled env gw (q + 1) f))
    ++ next rest
  CSys ls rest -> concatMap (ppSys env q) ls ++ next rest
  CReturn tmp k val -> when (kindSize k > 0) [ppTmp tmp ++ " = " ++ ex val]
  -- Printed even when kIn or kOut has size 0, since the call updates the Gallina register
  CCallGallina (_, gIdx) kIn e kOut _ tmp@(_, site) rest ->
    let out = call "guru_gallina_call"
                [show site, show gIdx, "guru_cycle", show gw, toBits env kIn (ex e), show (kindSize kOut)]
    in stmt q (if kindSize kOut > 0 then ppTmp tmp ++ " = " ++ fromBits env kOut out else call "guru_drop" [out])
       ++ next rest
  where
    ex = ppExpr env
    next = ppCompiled env gw q
    when cond strs = if cond then concatMap (stmt q) strs else ""
    isMem sz k ports = kindSize k > 0 && sz > 0 && ports > 0

-- ---------------------------------------------------------------------------------
-- Kinds used by the module, for hoisting

exprKinds :: CExpr -> [Kind]
exprKinds e = case e of
  Var k _ -> [k]
  Const k _ -> [k]
  Or k ls -> k : concatMap exprKinds ls
  And k ls -> k : concatMap exprKinds ls
  Xor k ls -> k : concatMap exprKinds ls
  Not k a -> k : exprKinds a
  TruncLsb _ _ a -> exprKinds a
  TruncMsb _ _ a -> exprKinds a
  UXor _ a -> exprKinds a
  Add _ ls -> concatMap exprKinds ls
  Mul _ ls -> concatMap exprKinds ls
  Div _ a b -> exprKinds a ++ exprKinds b
  Rem _ a b -> exprKinds a ++ exprKinds b
  Sll _ _ a b -> exprKinds a ++ exprKinds b
  Srl _ _ a b -> exprKinds a ++ exprKinds b
  Sra _ _ a b -> exprKinds a ++ exprKinds b
  Concat _ _ a b -> exprKinds a ++ exprKinds b
  ITE k p t f -> k : exprKinds p ++ exprKinds t ++ exprKinds f
  Eq0 k a b -> k : exprKinds a ++ exprKinds b
  Ult _ a b -> exprKinds a ++ exprKinds b
  ReadStruct ls a _ -> Struct ls : exprKinds a
  ReadArray n _ k a i -> Array n k : exprKinds a ++ exprKinds i
  ReadArrayConst n k a _ -> Array n k : exprKinds a
  UpdateStruct ls a _ v -> Struct ls : exprKinds a ++ exprKinds v
  UpdateArray n k a _ p v -> Array n k : exprKinds a ++ exprKinds p ++ exprKinds v
  UpdateArrayConst n k a _ v -> Array n k : exprKinds a ++ exprKinds v
  ToBit k a -> k : exprKinds a
  FromBit k a -> k : exprKinds a
  ReadUnionTag ls a _ -> TaggedUnion ls : exprKinds a
  ReadUnionData ls a _ -> TaggedUnion ls : exprKinds a
  BuildUnion ls _ a -> TaggedUnion ls : exprKinds a
  BuildStruct ls vals -> Struct ls : concatMap (\v -> exprKinds (unsafeCoerce v :: CExpr)) (tupleToList ls vals)
  BuildArray n k vals -> Array n k : concatMap exprKinds vals

codeKinds :: Compiled -> [Kind]
codeKinds c = case c of
  CReadReg _ k _ rest -> k : codeKinds rest
  CWriteReg _ k val rest -> k : exprKinds val ++ codeKinds rest
  CReadRqMem _ _ k _ i _ rest -> k : exprKinds i ++ codeKinds rest
  CReadRpMem _ _ k _ _ _ rest -> k : codeKinds rest
  CWriteMem _ _ k _ i val rest -> k : exprKinds i ++ exprKinds val ++ codeKinds rest
  CSend _ k e rest -> k : exprKinds e ++ codeKinds rest
  CRecv _ k _ rest -> k : codeKinds rest
  CLetExpr _ k e rest -> k : exprKinds e ++ codeKinds rest
  CLetAction k act rest -> k : codeKinds act ++ codeKinds rest
  CNonDet _ k rest -> k : codeKinds rest
  CIfElse p k t f rest -> k : exprKinds p ++ codeKinds t ++ codeKinds f ++ codeKinds rest
  CSys ls rest -> concatMap sysKinds ls ++ codeKinds rest
  CReturn _ k val -> k : exprKinds val
  CCallGallina _ kIn e kOut _ _ rest -> kIn : kOut : exprKinds e ++ codeKinds rest
  where
    sysKinds (DispExpr k e _) = k : exprKinds e
    sysKinds _ = []

elemKinds :: Elem -> [Kind]
elemKinds (EReg (Build_Reg k _)) = [k]
elemKinds (EMem (Build_Mem _ k _ _)) = [k]
elemKinds (ESend k) = [k]
elemKinds (ERecv k) = [k]
elemKinds (EGallinaReg _) = []

-- ---------------------------------------------------------------------------------
-- Module

-- State elements. Initial values follow InitStateElem: the given value, else the default.
ppElemDecl :: Env -> (Integer, (String, Elem)) -> String
ppElemDecl env (i, (s, EReg (Build_Reg k initVal))) =
  "register " ++ ppReg (s, i) ++ " : " ++ ty env k ++ " = " ++ maybe (zero env k) (ppConst env k) initVal ++ "\n"
ppElemDecl env (i, (s, EMem (Build_Mem n k p initVal))) =
  let ramInit = case initVal of
        Just (Just val) -> ppConst env (Array n k) val
        _ -> call "vector_init" [zero env k]
  in "register " ++ ppMem "Ram" (s, i) ++ " : " ++ ty env (Array n k) ++ " = " ++ ramInit ++ "\n"
     ++ "register " ++ ppMem "Rp" (s, i) ++ " : " ++ ty env (Array p k) ++ " = " ++ call "vector_init" [zero env k] ++ "\n"
ppElemDecl _ _ = ""

-- One function per method, over the generic guru_send / guru_recv of the runtime
ppMethDecl :: Env -> (Integer, (String, Elem)) -> String
ppMethDecl env (i, (s, ESend k)) =
  let name = ppMeth "Send" (s, i)
  in "function " ++ name ++ "(v : " ++ ty env k ++ ") -> unit = " ++ call "guru_send" [sailString name, toBits env k "v"] ++ "\n"
ppMethDecl env (i, (s, ERecv k)) =
  let name = ppMeth "Recv" (s, i)
  in "function " ++ name ++ "() -> " ++ ty env k ++ " = " ++ fromBits env k (call "guru_recv" [sailString name, show (kindSize k)]) ++ "\n"
ppMethDecl _ _ = ""

ppSailTop :: CompiledModule -> String
ppSailTop (((_, tree), tmpsRaw), code) =
  let elems = filteredElems tree
      len = genericLength tmpsRaw :: Integer
      tmps = [(s, len - 1 - i, k) | (i, (s, k)) <- tag tmpsRaw, kindSize k > 0]
      named = numberKinds (concatMap (elemKinds . snd . snd) elems ++ map snd tmpsRaw ++ codeKinds code)
      env = M.fromList [(kindKey k, name) | (k, name) <- named]
      gw = gallinaWidth (gallinaCalls code)
  in "/* Generated by GuruSail from a Guru compiled module. Compile together with GuruLibrary.sail. */\n\n"
     ++ concatMap (ppKindDecl env) named
     ++ concatMap (ppElemDecl env) elems ++ "\n"
     ++ "register guru_cycle : int = 0\n"
     ++ "register guru_finished : bool = false\n\n"
     ++ concatMap (ppMethDecl env) elems ++ "\n"
     ++ "/* One clock cycle */\n"
     ++ "val step : unit -> unit\n"
     ++ "function step() = {\n"
     ++ concat [stmt 1 ("var " ++ ppTmp (s, i) ++ " : " ++ ty env k ++ " = " ++ zero env k) | (s, i, k) <- tmps]
     ++ "\n"
     ++ ppCompiled env gw 1 code
     ++ "\n"
     ++ stmt 1 "guru_cycle = guru_cycle + 1"
     ++ "}\n\n"
     ++ "val main : unit -> unit\n"
     ++ "function main() = {\n"
     ++ stmt 1 "let max_cycles = guru_max_cycles()"
     ++ stmt 1 "while not_bool(guru_finished) & guru_cycle < max_cycles do step()"
     ++ "}\n"
