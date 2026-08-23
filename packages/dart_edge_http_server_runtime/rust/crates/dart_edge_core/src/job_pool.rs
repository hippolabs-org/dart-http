use std::collections::HashMap;
use std::fmt;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicI64, AtomicU64, AtomicUsize, Ordering},
    mpsc::{Receiver, SyncSender},
};
use std::thread::{self, JoinHandle};

use crate::NativeCompletionPort;

/// Poll state for a submitted native job.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeJobPoll {
    /// The job has not finished yet, or the id is unknown.
    Pending,
    /// The job finished successfully.
    Success,
    /// The job finished with an error.
    Failure,
}

/// Submit failure for a native job pool.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeJobSubmitError {
    /// The bounded job queue is full.
    QueueFull,
    /// The worker channel is closed.
    Closed,
}

impl fmt::Display for NativeJobSubmitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::QueueFull => f.write_str("native job queue is full"),
            Self::Closed => f.write_str("native job pool is closed"),
        }
    }
}

impl std::error::Error for NativeJobSubmitError {}

/// Snapshot of native job pool counters.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeJobPoolMetrics {
    /// Number of worker threads owned by the pool.
    pub worker_count: usize,
    /// Maximum number of queued jobs accepted by the pool.
    pub max_queue_size: usize,
    /// Jobs submitted to the pool API.
    pub submitted_jobs: u64,
    /// Jobs accepted into the queue.
    pub accepted_jobs: u64,
    /// Jobs rejected because the queue was full.
    pub rejected_queue_full_jobs: u64,
    /// Jobs rejected because the pool was closed.
    pub rejected_closed_jobs: u64,
    /// Jobs that a worker has started processing.
    pub started_jobs: u64,
    /// Jobs completed successfully.
    pub completed_success_jobs: u64,
    /// Jobs completed with an error.
    pub completed_error_jobs: u64,
    /// Completed results waiting to be taken by the caller.
    pub pending_result_count: usize,
    /// Jobs accepted into the queue but not yet started by a worker.
    pub queued_jobs: usize,
    /// Jobs currently running on worker threads.
    pub active_jobs: usize,
    /// Highest observed queue depth.
    pub max_observed_queued_jobs: usize,
    /// Highest observed active worker count.
    pub max_observed_active_jobs: usize,
    /// Completion notifications that the Dart VM rejected or could not receive.
    pub completion_post_failed_jobs: u64,
}

#[derive(Debug)]
struct NativeJobPoolCounters {
    worker_count: usize,
    max_queue_size: usize,
    submitted_jobs: AtomicU64,
    accepted_jobs: AtomicU64,
    rejected_queue_full_jobs: AtomicU64,
    rejected_closed_jobs: AtomicU64,
    started_jobs: AtomicU64,
    completed_success_jobs: AtomicU64,
    completed_error_jobs: AtomicU64,
    queued_jobs: AtomicUsize,
    active_jobs: AtomicUsize,
    max_observed_queued_jobs: AtomicUsize,
    max_observed_active_jobs: AtomicUsize,
    completion_post_failed_jobs: AtomicU64,
}

impl NativeJobPoolCounters {
    fn new(worker_count: usize, max_queue_size: usize) -> Self {
        Self {
            worker_count,
            max_queue_size,
            submitted_jobs: AtomicU64::new(0),
            accepted_jobs: AtomicU64::new(0),
            rejected_queue_full_jobs: AtomicU64::new(0),
            rejected_closed_jobs: AtomicU64::new(0),
            started_jobs: AtomicU64::new(0),
            completed_success_jobs: AtomicU64::new(0),
            completed_error_jobs: AtomicU64::new(0),
            queued_jobs: AtomicUsize::new(0),
            active_jobs: AtomicUsize::new(0),
            max_observed_queued_jobs: AtomicUsize::new(0),
            max_observed_active_jobs: AtomicUsize::new(0),
            completion_post_failed_jobs: AtomicU64::new(0),
        }
    }

    fn snapshot(&self, pending_result_count: usize) -> NativeJobPoolMetrics {
        NativeJobPoolMetrics {
            worker_count: self.worker_count,
            max_queue_size: self.max_queue_size,
            submitted_jobs: self.submitted_jobs.load(Ordering::Relaxed),
            accepted_jobs: self.accepted_jobs.load(Ordering::Relaxed),
            rejected_queue_full_jobs: self.rejected_queue_full_jobs.load(Ordering::Relaxed),
            rejected_closed_jobs: self.rejected_closed_jobs.load(Ordering::Relaxed),
            started_jobs: self.started_jobs.load(Ordering::Relaxed),
            completed_success_jobs: self.completed_success_jobs.load(Ordering::Relaxed),
            completed_error_jobs: self.completed_error_jobs.load(Ordering::Relaxed),
            pending_result_count,
            queued_jobs: self.queued_jobs.load(Ordering::Relaxed),
            active_jobs: self.active_jobs.load(Ordering::Relaxed),
            max_observed_queued_jobs: self.max_observed_queued_jobs.load(Ordering::Relaxed),
            max_observed_active_jobs: self.max_observed_active_jobs.load(Ordering::Relaxed),
            completion_post_failed_jobs: self.completion_post_failed_jobs.load(Ordering::Relaxed),
        }
    }
}

/// Bounded native worker-thread pool with retrievable job results.
///
/// The pool owns a fixed set of Rust threads. Each thread creates one
/// long-lived handler from the provided factory, then processes submitted jobs
/// sequentially on that thread. Results are stored by job id until callers
/// remove them with [`NativeJobPool::take_result`].
pub struct NativeJobPool<I, O, E = String> {
    sender: Option<SyncSender<NativeJobPoolMessage<I>>>,
    results: Arc<Mutex<HashMap<i64, Result<O, E>>>>,
    counters: Arc<NativeJobPoolCounters>,
    completion_port: NativeCompletionPort,
    next_job_id: AtomicI64,
    workers: Vec<JoinHandle<()>>,
}

enum NativeJobPoolMessage<I> {
    Run { job_id: i64, input: I },
}

impl<I, O, E> NativeJobPool<I, O, E>
where
    I: Send + 'static,
    O: Send + 'static,
    E: Send + 'static,
{
    /// Creates a bounded native job pool.
    ///
    /// `handler_factory` is called once per worker thread. The returned
    /// handler is reused for every job handled by that worker, which makes this
    /// useful for expensive native state such as inference sessions.
    pub fn new<F, H>(
        worker_count: usize,
        max_queue_size: usize,
        handler_factory: F,
    ) -> Result<Self, String>
    where
        F: Fn() -> H + Send + Sync + 'static,
        H: FnMut(I) -> Result<O, E> + Send + 'static,
    {
        Self::new_with_completion(
            worker_count,
            max_queue_size,
            NativeCompletionPort::new(0),
            handler_factory,
        )
    }

    /// Creates a bounded native job pool with Dart completion notifications.
    ///
    /// The pool stores each result by job id, then posts that job id to
    /// `completion_port` after the result is available. Callers should still
    /// retrieve the result with [`NativeJobPool::take_result`].
    pub fn new_with_completion<F, H>(
        worker_count: usize,
        max_queue_size: usize,
        completion_port: NativeCompletionPort,
        handler_factory: F,
    ) -> Result<Self, String>
    where
        F: Fn() -> H + Send + Sync + 'static,
        H: FnMut(I) -> Result<O, E> + Send + 'static,
    {
        if worker_count == 0 {
            return Err("native job pool worker_count must be at least 1.".to_string());
        }
        if max_queue_size == 0 {
            return Err("native job pool max_queue_size must be at least 1.".to_string());
        }

        let (sender, receiver) = std::sync::mpsc::sync_channel(max_queue_size);
        let receiver = Arc::new(Mutex::new(receiver));
        let results = Arc::new(Mutex::new(HashMap::new()));
        let counters = Arc::new(NativeJobPoolCounters::new(worker_count, max_queue_size));
        let handler_factory = Arc::new(handler_factory);
        let mut workers = Vec::with_capacity(worker_count);

        for _ in 0..worker_count {
            workers.push(spawn_native_job_worker(
                Arc::clone(&receiver),
                Arc::clone(&results),
                Arc::clone(&counters),
                completion_port,
                Arc::clone(&handler_factory),
            ));
        }

        Ok(Self {
            sender: Some(sender),
            results,
            counters,
            completion_port,
            next_job_id: AtomicI64::new(1),
            workers,
        })
    }

    /// Submits a job to the bounded queue and returns its job id.
    pub fn submit(&self, input: I) -> Result<i64, NativeJobSubmitError> {
        self.counters.submitted_jobs.fetch_add(1, Ordering::Relaxed);
        let job_id = self.next_job_id.fetch_add(1, Ordering::Relaxed);
        let Some(sender) = &self.sender else {
            self.counters
                .rejected_closed_jobs
                .fetch_add(1, Ordering::Relaxed);
            return Err(NativeJobSubmitError::Closed);
        };
        match sender.try_send(NativeJobPoolMessage::Run { job_id, input }) {
            Ok(()) => {
                self.counters.accepted_jobs.fetch_add(1, Ordering::Relaxed);
                let queued = self.counters.queued_jobs.fetch_add(1, Ordering::Relaxed) + 1;
                update_atomic_max(&self.counters.max_observed_queued_jobs, queued);
                Ok(job_id)
            }
            Err(std::sync::mpsc::TrySendError::Full(_)) => {
                self.counters
                    .rejected_queue_full_jobs
                    .fetch_add(1, Ordering::Relaxed);
                Err(NativeJobSubmitError::QueueFull)
            }
            Err(std::sync::mpsc::TrySendError::Disconnected(_)) => {
                self.counters
                    .rejected_closed_jobs
                    .fetch_add(1, Ordering::Relaxed);
                Err(NativeJobSubmitError::Closed)
            }
        }
    }

    /// Polls a submitted job without removing its result.
    pub fn poll(&self, job_id: i64) -> NativeJobPoll {
        let results = self.results.lock().unwrap();
        match results.get(&job_id) {
            Some(Ok(_)) => NativeJobPoll::Success,
            Some(Err(_)) => NativeJobPoll::Failure,
            None => NativeJobPoll::Pending,
        }
    }

    /// Takes a finished job result.
    ///
    /// Returns `None` when the job id is unknown or not ready yet.
    ///
    /// Completed results stay in memory until they are taken or the pool is
    /// dropped.
    pub fn take_result(&self, job_id: i64) -> Option<Result<O, E>> {
        self.results.lock().unwrap().remove(&job_id)
    }

    /// Returns the number of completed results waiting to be taken.
    pub fn pending_result_count(&self) -> usize {
        self.results.lock().unwrap().len()
    }

    /// Returns a point-in-time snapshot of pool counters.
    pub fn metrics(&self) -> NativeJobPoolMetrics {
        self.counters.snapshot(self.pending_result_count())
    }

    /// Returns the configured Dart completion notifier.
    pub const fn completion_port(&self) -> NativeCompletionPort {
        self.completion_port
    }
}

impl<I, O, E> Drop for NativeJobPool<I, O, E> {
    fn drop(&mut self) {
        drop(self.sender.take());
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

fn spawn_native_job_worker<I, O, E, F, H>(
    receiver: Arc<Mutex<Receiver<NativeJobPoolMessage<I>>>>,
    results: Arc<Mutex<HashMap<i64, Result<O, E>>>>,
    counters: Arc<NativeJobPoolCounters>,
    completion_port: NativeCompletionPort,
    handler_factory: Arc<F>,
) -> JoinHandle<()>
where
    I: Send + 'static,
    O: Send + 'static,
    E: Send + 'static,
    F: Fn() -> H + Send + Sync + 'static,
    H: FnMut(I) -> Result<O, E> + Send + 'static,
{
    thread::spawn(move || {
        let mut handler = handler_factory();
        loop {
            let message = match receiver.lock().unwrap().recv() {
                Ok(message) => message,
                Err(_) => break,
            };

            match message {
                NativeJobPoolMessage::Run { job_id, input } => {
                    counters.queued_jobs.fetch_sub(1, Ordering::Relaxed);
                    counters.started_jobs.fetch_add(1, Ordering::Relaxed);
                    let active = counters.active_jobs.fetch_add(1, Ordering::Relaxed) + 1;
                    update_atomic_max(&counters.max_observed_active_jobs, active);

                    let result = handler(input);
                    if result.is_ok() {
                        counters
                            .completed_success_jobs
                            .fetch_add(1, Ordering::Relaxed);
                    } else {
                        counters
                            .completed_error_jobs
                            .fetch_add(1, Ordering::Relaxed);
                    }
                    {
                        results.lock().unwrap().insert(job_id, result);
                    }
                    counters.active_jobs.fetch_sub(1, Ordering::Relaxed);
                    if !completion_port.post_job_id(job_id) && !completion_port.is_empty() {
                        counters
                            .completion_post_failed_jobs
                            .fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
        }
    })
}

fn update_atomic_max(value: &AtomicUsize, candidate: usize) {
    let mut current = value.load(Ordering::Relaxed);
    while candidate > current {
        match value.compare_exchange_weak(current, candidate, Ordering::Relaxed, Ordering::Relaxed)
        {
            Ok(_) => break,
            Err(next) => current = next,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_jobs_on_worker_threads() {
        let pool: NativeJobPool<i32, i32, String> =
            NativeJobPool::new(2, 4, || |value: i32| Ok(value * 2)).unwrap();

        let first = pool.submit(21).unwrap();
        let second = pool.submit(7).unwrap();

        let first_result = wait_for_result(&pool, first);
        let second_result = wait_for_result(&pool, second);

        assert_eq!(first_result.unwrap(), 42);
        assert_eq!(second_result.unwrap(), 14);
    }

    #[test]
    fn reports_job_failures() {
        let pool: NativeJobPool<i32, i32> =
            NativeJobPool::new(1, 1, || |_value: i32| Err("failed".to_string())).unwrap();

        let job_id = pool.submit(1).unwrap();
        let result = wait_for_result(&pool, job_id);

        assert_eq!(result.unwrap_err(), "failed");
    }

    #[test]
    fn reports_pool_metrics() {
        let pool: NativeJobPool<i32, i32, String> =
            NativeJobPool::new(1, 1, || |value: i32| Ok(value * 2)).unwrap();

        let first = pool.submit(21).unwrap();
        let full = pool.submit(7);

        assert_eq!(full, Err(NativeJobSubmitError::QueueFull));
        assert_eq!(wait_for_result(&pool, first).unwrap(), 42);

        let metrics = pool.metrics();
        assert_eq!(metrics.worker_count, 1);
        assert_eq!(metrics.max_queue_size, 1);
        assert_eq!(metrics.submitted_jobs, 2);
        assert_eq!(metrics.accepted_jobs, 1);
        assert_eq!(metrics.rejected_queue_full_jobs, 1);
        assert_eq!(metrics.started_jobs, 1);
        assert_eq!(metrics.completed_success_jobs, 1);
        assert_eq!(metrics.completed_error_jobs, 0);
        assert_eq!(metrics.pending_result_count, 0);
        assert!(metrics.max_observed_queued_jobs >= 1);
        assert!(metrics.max_observed_active_jobs >= 1);
    }

    fn wait_for_result<I, O, E>(pool: &NativeJobPool<I, O, E>, job_id: i64) -> Result<O, E>
    where
        I: Send + 'static,
        O: Send + 'static,
        E: Send + 'static,
    {
        for _ in 0..1000 {
            if pool.poll(job_id) != NativeJobPoll::Pending {
                return pool.take_result(job_id).unwrap();
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        panic!("native job did not finish");
    }
}
