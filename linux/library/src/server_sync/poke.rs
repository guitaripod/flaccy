use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

/// A shared flag the GUI sets to ask for a sync soon: a local change, a focus event, a server poke.
#[derive(Clone, Default)]
pub struct PokeHandle {
    inner: Arc<(Mutex<bool>, Condvar)>,
}

impl PokeHandle {
    /// Asks the sync loop to run now.
    pub fn poke(&self) {
        let (flag, wake) = &*self.inner;
        if let Ok(mut raised) = flag.lock() {
            *raised = true;
            wake.notify_all();
        }
    }

    /// Waits up to `timeout` for a poke; true when one arrived. Clears the flag.
    pub fn wait(&self, timeout: Duration) -> bool {
        let (flag, wake) = &*self.inner;
        let Ok(mut raised) = flag.lock() else {
            return false;
        };
        if !*raised {
            raised = match wake.wait_timeout(raised, timeout) {
                Ok((guard, _)) => guard,
                Err(_) => return false,
            };
        }
        std::mem::replace(&mut *raised, false)
    }
}
