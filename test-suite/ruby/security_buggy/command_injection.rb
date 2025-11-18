# frozen_string_literal: true

params = { file: ARGV[0] || '/tmp/data.txt' }

# BUG: shell invocation composed from user input
system("rm -rf #{params[:file]}")

# BUG: backticks also interpolate untrusted data
contents = `cat #{params[:file]}`
puts contents
