Thread.new do
  raise 'background boom'
end

Thread.new do
  user = fetch_user
  puts user.name
end

def fetch_user
  raise 'network'
end
