Thread.new do
  begin
    fetch_user
  rescue => e
    warn "background error: #{e.message}"
  end
end

def fetch_user
  'user'
end
