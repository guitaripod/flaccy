use std::sync::{Mutex, MutexGuard, PoisonError};

/// Locks `mutex`, treating a poisoned lock as still usable: a panicked harness thread must not hide the evidence behind it.
pub fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
