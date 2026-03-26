# To Do:

- [x] Multi-threaded Accept:
    - have to use `SO.REUSEPORT`

- [-]  Multi-threaded dispatch using the thread pool
    - `thread_pool.spawn(Client.process, .{client})`
    - Exploration Results: Unfeasible, since each `handle-event` cannot be done in isolation since it mutates the server structures
    - Either make those structures, thread-safe. which is also unfeasible since, there are `bool` and other non-atomic values. Tricky to make locks/semaphores

- [x] Platform Abstractions
    - Iterator and Event union

- [-] Unblocking the wait:
    - We can use `posix.pipe`. where one end is the read end and another is write
    - `Epoll` have `eventfd` support for one-time signal to Unblocking
    - `Kqueue` can utilize `EVFILT.USER` filter
    - Note: I am not sure where to integrate this one?? 
    - Why do we need to explicitly.. mainly shutdown
    - This is useful in shutdown situations, when we might need to signal the caller thread to shutdown a specific listener/thread  

- [-] `linux.EPOLL.exclusive`:
    - listeners are going to compete for the connecting sockets
    - we restrict it to use only on listeners or epoll/loop
    - Caveat: Kqueue implementation for this is messy with 2 syscall 
    - More detail on why:  
    - Apple setsockopt with the REUSEPORT doesnt guarantee the LB.
    - thus it always use the exisiting the listener. 
    - however, if it does in linux use cases, the poll will be attched to the given listener only
    - thus events will always be correctly poll-ed to the right listener
    - Might be usefull in some prooduction situations but clasically overkill for current state

- [ ] Timeout Enforcement `enforceTimeout() in server.zig` 
    - [x] Fix a simple kqueue bug for infinite wait
    - Might be better represented using min-heap


# things that is bothering me:
- Type inference for Zig generics.
    - This might missing LSP specific features.
    - I think `comptime + return strcut` should have some inference checking
 
# Notes:
- Client and Reader are not thread-safe.
    - Reader is difficult to make it thread-safe since it 
        needs to handle different reader position per thread
- Give each thread a client.
    - system might be underutilized. 
    - heavy users might drain the resources heavily 
    - this what erlang/elixir does 
