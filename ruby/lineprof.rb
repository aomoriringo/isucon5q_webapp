if ARGV.size == 0
  puts "USAGE:"
  puts "ruby ./lineprof.rb [log file] [threshold(ms) = 0]"
  exit 0
end

file = ARGV.first
threshold = ARGV.last.to_i

lines = IO.readlines(file)
lines.map { |l|
  l.match(%r`(\d+\.\d+)ms.+\s+\d+\s+\|\s+(\d+)\s+(.+)`)
}.compact.select{ |m|
  m[1].to_f > threshold
}.group_by{ |m|
  m[2]
}.sort_by{ |g|
  g[1].map{ |m| m[1].to_f }.inject(:+)
}.map{ |g|
  line, matches = g
  total = matches.map{ |m| m[1].to_f }.inject(:+).ceil
  puts "line:  %s" % line
  puts "total: %sms" % total
  puts "avg  : %sms" % ( total / matches.size ).ceil
  matches.sort{ |a, b|
    b[1].to_f <=> a[1].to_f
  }.each do |m|
    puts "  => %s" % m[0]
  end
  puts
}

