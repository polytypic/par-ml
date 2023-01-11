let null _ = Obj.magic () [@@inline]
let impossible () = failwith "impossible"
