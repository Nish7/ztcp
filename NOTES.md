# To Do:

- [x] Multi-threaded Accept:
    - have to use `SO.REUSEPORT`

- [] Multi-threaded dispatch using the thread pool
    - `thread_pool.spawn(Client.process, .{client})`

- [x] Platform Abstractions
    - Iterator and Event union

- [] Unblocking the wait:
    - We can use `posix.pipe`. where one end is the read end and another is write
    - `Epoll` have `eventfd` support for one-time signal to Unblocking
    - `Kqueue` can utilize `EVFILT.USER` filter
    - Note: I am not sure where to integrate this one?? 
    - Why do we need to explicitly.. mainly shutdown

- [] `linux.EPOLL.exclusive`:
    - listeners are going to compete for the connecting sockets
    - we restrict it to use only on listeners or epoll/loop
    - Caveat: Kqueue implementation for this is messy with 2 syscall 
    - More detail on why:  
    - Apple setsockopt with the REUSEPORT doesnt guarantee the LB.
    - thus it always use the exisiting the listener. 
    - however, if it does in linux use cases, the poll will be attched to the given listener only
    - thus events will always be correctly poll-ed to the right listener
    

# things that is bothering me:
- Type inference for zig generics
 
# Notes:
- Client and Reader are not thread-safe.
    - Reader is difficult to make it thread-safe since it 
        needs to handle different reader position per thread
- Give each thread a client.
    - system might be underutilized. 
    - heavy users might drain the resources heavily 
    - this what erlang/elixir does 
