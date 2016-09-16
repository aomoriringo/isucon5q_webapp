worker_processes 23
preload_app true
listen "/home/isucon/webapp/ruby/tmp/unicorn.sock", backlog: 1024
pid "/home/isucon/webapp/ruby/unicorn.pid"

#stderr_path File.expand_path('/var/log/unicorn/err.log', __FILE__)
#stdout_path File.expand_path('/var/log/unicorn/out.log', __FILE__)
