module SeqCoins where

data AList = ANil | ASing Int | Append AList AList

data Coins = Cons Int Int Coins
           | Nil

lenA :: AList -> Int
lenA ls =
    case ls of
        ANil -> 0
        ASing i -> 1
        Append l r -> lenA l + lenA r

getCoins1 :: Int -> Int -> [(Int,Int)] -> [(Int,Int)]
getCoins1 c q coins =
    let len = vlength coins
    in if q == 1 then (vslice coins 0 len) else vsnoc coins (c,q-1)

getCoinsRst :: [(Int,Int)] -> [(Int,Int)]
getCoinsRst coins =
    let len = vlength coins
    in vslice coins 0 (len-1)

payA :: Int -> [(Int,Int)] -> AList
payA amt coins =
    if amt == 0
    then ASing 1
    else
        let len = vlength coins
        in if len == 0
        then ANil
        else
            let tup = vnth (len-1) coins
                c = tup !!! 0
                q = tup !!! 1
                coins_rst = getCoinsRst coins
            in if c > amt
            then payA amt coins_rst
            else
                let coins1 = getCoins1 c q coins_rst
                    left = payA (amt - c) coins1
                    right = payA amt coins_rst
                in Append left right

gibbon_main =
    let coins :: [(Int,Int)]
        coins = vempty
        _ = inplacevsnoc coins (250,55)
        _ = inplacevsnoc coins (100,88)
        _ = inplacevsnoc coins (25,88)
        _ = inplacevsnoc coins (10,99)
        _ = inplacevsnoc coins (5,122)
        _ = inplacevsnoc coins (1,177)
        amt = sizeParam
        tr = iterate (payA amt coins)
    in lenA tr
