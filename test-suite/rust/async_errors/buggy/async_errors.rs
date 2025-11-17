use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

async fn fetch_data() -> Result<String, &'static str> {
    Err("network")
}

async fn run() {
    let body = fetch_data().await;
    println!("{:?}", body);
    let handle = tokio::spawn(async move {
        let _ = fetch_data().await;
    });
    println!("spawned: {:?}", handle);
}

fn main() {
    let _ = run();
}

mod tokio {
    use super::*;

    pub struct JoinHandle;

    impl std::fmt::Debug for JoinHandle {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("JoinHandle")
        }
    }

    impl Future for JoinHandle {
        type Output = Result<(), ()>;

        fn poll(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Self::Output> {
            Poll::Ready(Ok(()))
        }
    }

    impl JoinHandle {
        pub fn abort(&self) {}
    }

    pub fn spawn<F>(_f: F) -> JoinHandle
    where
        F: Future<Output = ()> + Send + 'static,
    {
        JoinHandle
    }
}
