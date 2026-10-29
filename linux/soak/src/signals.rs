/// Clears the blocked-signal mask of this thread so the server children it spawns inherit a clean one and can be stopped with SIGTERM. Some launchers start their children with SIGTERM blocked, and a blocked SIGTERM never reaches the server's handler.
pub fn unblock_all() {
    let mut set = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
    unsafe {
        libc::sigemptyset(set.as_mut_ptr());
        libc::pthread_sigmask(libc::SIG_SETMASK, set.as_ptr(), std::ptr::null_mut());
    }
}
