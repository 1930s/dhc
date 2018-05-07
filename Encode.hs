module Encode where

import Data.Bits
import Data.Char
import WasmOp

data WasmFun = WasmFun
  { typeSig :: Int
  , localCount :: Int  -- We only support functions with I32 locals.
  , funBody :: [WasmOp]
  } deriving Show

wasmHeader :: [Int]
wasmHeader = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]  -- Magic string, version.

encWasmOp :: WasmOp -> [Int]
encWasmOp op = case op of
  Get_local n -> 0x20 : leb128 n
  Set_local n -> 0x21 : leb128 n
  Tee_local n -> 0x22 : leb128 n
  Get_global n -> 0x23 : leb128 n
  Set_global n -> 0x24 : leb128 n
  I64_const n -> 0x42 : sleb128 n
  I32_const n -> 0x41 : sleb128 n
  Call n -> 0x10 : leb128 n
  Call_indirect n -> 0x11 : leb128 n ++ [0]
  I64_load m n -> [0x29, m, n]
  I64_store m n -> [0x37, m, n]
  I32_load m n -> [0x28, m, n]
  I32_load8_u m n -> [0x2d, m, n]
  I32_load16_u m n -> [0x2f, m, n]
  I32_store m n -> [0x36, m, n]
  I32_store8 m n -> [0x3a, m, n]
  Br n -> 0xc : leb128 n
  Br_if n -> 0xd : leb128 n
  Br_table bs a -> 0xe : leb128 (length bs) ++ concatMap leb128 (bs ++ [a])
  If t as [] -> [0x4, encType t] ++ concatMap encWasmOp as ++ [0xb]
  If t as bs -> concat
    [ [0x4, encType t]
    , concatMap encWasmOp as
    , [0x5]
    , concatMap encWasmOp bs
    , [0xb]
    ]
  Block t as -> [2, encType t] ++ concatMap encWasmOp as ++ [0xb]
  Loop t as -> [3, encType t] ++ concatMap encWasmOp as ++ [0xb]
  _ -> maybe (error $ "unsupported: " ++ show op) pure $ lookup op rZeroOps

enc32 :: Int -> [Int]
enc32 n = (`mod` 256) . (div n) . (256^) <$> [(0 :: Int)..3]

encMartinType :: WasmType -> Int
encMartinType t = case t of
  Ref "Actor" -> 0x6f
  Ref "Module" -> 0x6e
  Ref "Port" -> 0x6d
  Ref "Databuf" -> 0x6c
  Ref "Elem" -> 0x6b
  _ -> encType t

encType :: WasmType -> Int
encType t = case t of
  I32 -> 0x7f
  I64 -> 0x7e
  F32 -> 0x7d
  F64 -> 0x7c
  AnyFunc -> 0x70
  Nada -> 0x40
  _ -> error $ "bad type:" ++ show t

standardType :: WasmType -> WasmType
standardType t = case t of
  Ref _ -> I32
  _ -> t

leb128 :: Int -> [Int]
leb128 n | n < 128   = [n]
         | otherwise = 128 + (n `mod` 128) : leb128 (n `div` 128)

sleb128 :: (Bits a, Integral a) => a -> [Int]
sleb128 n | n < 0     = fromIntegral <$> (f (n .&. 127) $ shiftR n 7)
          | n < 64    = [fromIntegral n]
          | n < 128   = [128 + fromIntegral n, 0]
          | otherwise = 128 + (fromIntegral n `mod` 128) : sleb128 (n `div` 128)
          where
          f x (-1) | x < 64    = [x .|. 128, 127]
                   | otherwise = [x]
          f x y    = (x .|. 128):f (y .&. 127) (shiftR y 7)

sect :: Int -> [[Int]] -> [Int]
sect t xs = t : lenc (varlen xs ++ concat xs)

sectCustom :: String -> [[Int]] -> [Int]
sectCustom s xs = 0 : lenc (encStr s ++ varlen xs ++ concat xs)

encStr :: String -> [Int]
encStr s = lenc $ ord <$> s

-- | Encodes type section (1).
sectType :: [([WasmType], [WasmType])] -> [Int]
sectType = sect 1 . map encSig where
  encSig (ins, outs) = 0x60 : lenc (encType <$> ins) ++ lenc (encType <$> outs)

-- | Encodes import section (2).
sectImport :: [((String, String), Int)] -> [Int]
sectImport imps = sect 2 $ importFun <$> imps where
  importFun ((m, f), ty) = encStr m ++ encStr f ++ [0, ty]

-- | Encodes function section (3).
sectFunction :: [WasmFun] -> [Int]
sectFunction fs = sect 3 $ pure . typeSig <$> fs

-- | Encodes table section (4).
-- Selects "no-maximum" (0).
sectTable :: Int -> [Int]
sectTable sz = sect 4 [[encType AnyFunc, 0] ++ leb128 sz]

-- | Encodes code section (10).
sectCode :: [WasmFun] -> [Int]
sectCode fs = sect 10 $ encProcedure <$> fs where
  encProcedure (WasmFun _ 0 body) = lenc $ 0:concatMap encWasmOp body
  encProcedure (WasmFun _ n body) = lenc $ ([1, n, encType I32] ++) $ concatMap encWasmOp body

varlen :: [a] -> [Int]
varlen xs = leb128 $ length xs

lenc :: [Int] -> [Int]
lenc xs = varlen xs ++ xs

-- | Encodes persistent globals (0).
sectPersist :: [(Int, WasmType)] -> [Int]
sectPersist = sectCustom "persist" . fmap encMartinGlobal where
  encMartinGlobal (i, t) = [3] ++ leb128 i ++ leb128 (encMartinType t)