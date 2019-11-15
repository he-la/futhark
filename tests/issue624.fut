-- The problem was incorrect type substitution in the monomorphiser
-- which removed a uniqueness attribute.

module type m = {
    type t
    val r: *t -> *t
}

module m: m = {
    type t = [1]f32
    let r (t: *t): *t = t
}

entry r (t: *m.t): *m.t = m.r t
