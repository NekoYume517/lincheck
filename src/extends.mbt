// CI-20：MoonBit 0.1.20261117 不再把 trait 实现自动提升为具体类型的
// 点调用方法。集中显式公开既有 Model 实现，保持原有点调用 API 不变，
// 同时兼容仍接受旧点调用写法的 pinned 0.1.20261102。

///|
pub extend RegisterModel with Model::{
  name,
  init,
  apply,
  accepts,
  state_eq,
  state_hash,
}

///|
pub extend CounterModel with Model::{
  name,
  init,
  apply,
  accepts,
  state_eq,
  state_hash,
}

///|
pub extend SetModel with Model::{
  name,
  init,
  apply,
  accepts,
  state_eq,
  state_hash,
}

///|
pub extend QueueModel with Model::{
  name,
  init,
  apply,
  accepts,
  state_eq,
  state_hash,
}

///|
pub extend AnyModel with Model::{
  name,
  init,
  apply,
  accepts,
  state_eq,
  state_hash,
}

///|
pub extend OpResult with Eq::{equal}
