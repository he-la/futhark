-- Polymorphic function using polymorphic type in parametric module.
-- ==
-- input { 2 3 } output { [1,0] [2.0,1.0,0.0] }

module pm (P: { type vector [n] 't val reverse [n] 't: vector [n] t -> vector [n] t }) = {
  let reverse_pair [n] 'a [m] 'b ((xs,ys): (P.vector [n] a, P.vector [m] b)) =
    (P.reverse xs, P.reverse ys)
}

module m = pm { type vector [n] 't = [n]t let reverse [n] 't (xs: [n]t) = xs[::-1] }

let main (x: i32) (y: i32) = m.reverse_pair (iota x, map r64 (iota y))
