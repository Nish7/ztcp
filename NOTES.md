# Notes:
- Client and Reader are not thread-safe.
    - Reader is difficult to make it thread-safe since it 
        needs to handle differnt reader position per thread
- Give each thread a client.
    - system might be underutilized. 
    - heavy users might drain the resources heavily 
    - this what erlang/elixir does 

# Things to consider before i implement this:

1. Multi-threaded Accept:
    - have to use `SO.REUSEPORT`

2. Multi-threaded dispatch using the thread pool
    - `thread_pool.spawn(Client.process, .{client})`

3. Platform Abstractions
    - Iterator and Event union

4. Unblocking the wait 
    - We can use posix.pipe. where one end is the read end and another is write
    - Epoll have `eventfd` support for one-time signal to Unblocking
    - Kqueue can utilize `EVFILT.USER` filter
    - Note: I am not sure where to integreate this one?? 
    - Why do we need to explicitly.. mainly shutdown

5. linux.EPOLL.exclusive  for 

