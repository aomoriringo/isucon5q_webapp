worker_processes 8
preload_app true
listen 8080
pid "/home/isucon/webapp/ruby/unicorn.pid"


stderr_path File.expand_path('/var/log/unicorn/err.log', __FILE__)
stdout_path File.expand_path('/var/log/unicorn/out.log', __FILE__)
