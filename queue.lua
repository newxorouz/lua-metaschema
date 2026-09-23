local function queue()
	local t = {}
	t.contents = {}
	t.add = function(self, thing)
		table.insert(self.contents, thing)
	end
	t.get = function(self)
		if self:empty() then
			return nil
		end
		return table.remove(self.contents, 1)
	end
	t.empty = function(self)
		return #self.contents == 0
	end
	t.copy = function(self)
		local q = queue()
		for k, v in pairs(t.contents) do
			q.contents[k] = v
		end
		return q
	end
	t.unget = function(self, thing)
		table.insert(self.contents, 1, thing)
	end
	
	return t
end

local function smart_queue()
  --smart queue: don't use table.insert and table.remove
  --also, defer copying to write time
  --because the parser is going to make a lot of spurious copies with no additions
  --we will, however, create a new stack for ungetting in each instance of the queue
  local t = {}
  t.contents = {}
  t.unget_stack = {}
  t.unget_count = 0
  t.head = 0
  t.tail = 0
  t.add = function(self, thing)
    if self.deferredcopy then
      local new_contents = {}
      for k, v in pairs(self.contents) do
        if k >= self.tail and k < self.head then
          new_contents[k] = v
        end
      end
      self.contents = new_contents
      self.deferredcopy = false --we cloned. not a copy anymore.
    end
    self.contents[self.head] = thing
    self.head = self.head + 1
  end
  t.get = function(self)
    if self.unget_count ~= 0 then
      local toret = self.unget_stack[self.unget_count]
      self.unget_stack[self.unget_count] = nil
      self.unget_count = self.unget_count - 1
      return toret
    end
		if self:empty() then
			return nil
		end
    local toret = self.contents[self.tail]
    if not self.copied and not self.deferredcopy then
      self.contents[self.tail] = nil
    end
    --else let's not remove items. since a deferred copy might still read it./our parent, if we're ahead of it
    self.tail = self.tail + 1
		return toret
	end
	t.empty = function(self)
		return t.head == t.tail and self.unget_count == 0
	end
	t.copy = function(self)
    self.copied = true
    
		local q = smart_queue()
		q.contents = self.contents
    q.deferredcopy = true
    q.head = self.head
    q.tail = self.tail
    for k, v in pairs(self.unget_stack) do
      q.unget_stack[k] = v
    end
    q.unget_count = self.unget_count
		return q
	end
	t.unget = function(self, thing)
		self.unget_count = self.unget_count + 1
    self.unget_stack[self.unget_count] = thing
	end
	
	return t
end

return smart_queue