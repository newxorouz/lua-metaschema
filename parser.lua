--magic values for grammar rules:
-- _S is big sigma (the symbol everything else derives from)
-- _NAME is something that looks name-like and is not a keyword
-- _NUMBER is a number literal
-- _STRING is a quoted string value, in either single or double quotes
-- _TEXT is a hack to make markup languages (like xml) work. see below in lexer, in eat_text()

--[[ HOW TO USE:
  put
  
  local whatever = dofile("parser.lua")
  local parser = whatever()
  
  in your program. then make calls like
  parser:gr("A", {"B", "C"}) to denote a rule A -> B C for the grammar
  parser:star("A", "B") to denote a rule A -> B*
  parser:op("+") to indicate that + is an operator
  
  lastly, call parser:parse(put_string_here) to build a syntax tree out of the string
]]--

local queue = dofile("queue.lua")

local function parser()
	local t = {}
	t.rules = {}
	t.yet_to_eval = nil -- we will initialize when parse() is called
	t.terminal_states = {}
	
	t.lexables = {}
	t.lexables.keywords = {}
	t.lexables.operators = {}
  
  t.comments = {}
  t.comments.openers = {}
  t.comments.closers = {}
  
  t.config = {}
  t.config.namestart = "[%a_]"
  t.config.namemiddle = "[^%a_%d]" --note that namemiddle is presented in the negative
  t.config.openQuote = {'"'}
  t.config.closeQuote = {'"'} --these are not currently used
  
  t.config.enableText = false
  --t.config.textLDelim = ">"
  --t.config.textRDelim = "<"
  t.config.textPreserveDelims = true
  t.config.preserveEmptyText = false
  
  t.configure = function(self, param, setting)
    if param == "comment" then
      local code = #t.comments.closers + 1
      t.comments.openers[code] = setting[1]
      t.comments.closers[code] = setting[2]
    else
      t.config[param] = setting
    end
  end
	
	t.lex = function(self, str)
    if self.config.prelex ~= nil and type(self.config.prelex) == "function" then
      str = t.config.prelex(str)
    end
		local q = queue()
    
    local line = 1 --for better debugging when lexing throws an issue
		
		local function peek(n)
			n = n or 0
			return str:sub(1+n, 1+n)
		end
		
		local function advance(n)
      if n then
        for i = 1, n do
          advance()
        end
        return
      end
			local char = peek()
			str = str:sub(2)
      if char == "\n" then
        line = line + 1
      end
			return char
		end
    
    local function comment_opener()
      for k, v in pairs(self.comments.openers) do
        if str:sub(1, #v) == v then
          return k
        end
      end
      return false
    end
		
		local function eat_noncode() --whitespace and comments
			while true do
				while peek():match("%s") do
				--this could be an if. but this may be faster
				--(assuming whitespace comes in groups, which it does)
					advance()
				end
        local comment_type = comment_opener()
				if comment_type then
          advance(#self.comments.openers[comment_type])
          local closer = self.comments.closers[comment_type]
					while peek() ~= "" and str:sub(1, #closer) ~= closer do
						advance()
					end
          if peek()~= "" then
            advance(#closer)
          end
				else break end
			end
		end
		
		local function eat_string()
			local quote = advance()
			local result = ""
			while true do
				if peek() == "" then
					error("reached eof while compiling string")
				end
				if peek() == quote then
					advance()
					return result
				end
				if peek() == "\\" then
					advance()
					local r = {
						n="\n",
						r="\r",
						t="\t",
					}
					r["\\"] = "\\"
					r["'"] = "'"
					r['"'] = '"'
					--TODO: etc
					if not r[peek()] then
						error("unrecognized escape sequence \\"..peek().." on line "..line)
					end
					result = result .. r[advance()]
				else
					result = result .. advance()
				end
			end
			return result
		end
    
    local function eat_text()
      --okay. this is a hack to make xml work
      --xml is not a programming language strictly confined like the others
      --it descends from markdown languages, so human readable elements
      --are allowed just about anywhere in the document
      --(notice that it's a document and not code!)
      --however, we can't ignore these like comments (human-readable elements in code)
      --because unlike comments, the text in an XML document may be meaningful
      --(e.g. the data in a field. <game>Touhou Project</game> or something)
      --so maybe we could try parsing as a string, right?
      --in xml, text cannot occur inside a tag where the attributes go.
      --in other words, it will always be bounded to the left by a > and to the right by a <
      --BUT this doesn't work *because* xml also has comments and strings already
      --and strings exhibit some behaviors that text does not
      --for example "divided <-- comment --> string" does not include a comment
      --but <name>divided <--comment --> text</name> does
      --so we'll lex a new category of thing
      --this is what i'll lex as "text", if enabled
      
      advance(#self.config.textLDelim)
      if self.config.textPreserveDelims then
        q:add({name=self.config.textLDelim,value=self.config.textLDelim})
      end
      local result = ""
      while true do
        if peek() == "" then
          --unlike strings, it's perfectly fine to end on non-code
          return result, true
        end
        --because you can embed comments in text, check for comments before checking for end of text, in case they look similar
        --example: </tag>text<!--comment-->
        local comment_type = comment_opener()
				if comment_type then
          advance(#self.comments.openers[comment_type])
          local closer = self.comments.closers[comment_type]
					while peek() ~= "" and str:sub(1, #closer) ~= closer do
						advance()
					end
          if peek()~= "" then
            advance(#closer)
          end
				elseif str:sub(1, #self.config.textRDelim) == self.config.textRDelim then
          advance(#self.config.textRDelim)
          return result, false
        else
          result = result .. advance()
        end
      end
    end
		
		local function eat_number()
			local value = 0
			while true do
				if peek():match("%D") then
					break
				end
				value = value * 10 + advance()
			end
			if peek() == "." then
				advance()
				local place = 1
				while true do
					if peek():match("%D") then
						break
					end
					place = place / 10
					value = value + place * advance()
				end
			end
			return value
		end

		local function next_word()
			local str = ""
			while peek() ~= "" do
				if peek():match(self.config.namemiddle) then --[^%a_%d] by default
					return str
				end
				str = str .. advance()
			end
			return str
		end

		local function next_token(q)
			if peek():match(self.config.namestart) then --[%a_] by default
				local v = next_word()
				if self.lexables.keywords[v] ~= nil then
					q:add({name=v, value=v})
				else
					q:add({name="_NAME", value=v})
				end
				return
			end
			
			if peek():match("%d") then
				local v = eat_number()
				q:add({name="_NUMBER", value=v})
				return
			end
			
			if peek() == '"' or peek() == "'" then
				local v= eat_string()
				q:add({name="_STRING", value=v})
				return
			end
      
      if self.config.enableText then
        if peek() == self.config.textLDelim then
          local v, eof = eat_text()
          if v ~= "" or self.config.preserveEmptyText then
            q:add({name="_TEXT", value=v})
          end
          if self.config.textPreserveDelims and not eof then
            q:add({name=self.config.textRDelim,value=self.config.textRDelim})
          end
          return
        end
      end
			
			if self.lexables.operators[peek()] ~= nil then
				local v = advance()
				q:add({name=v, value=v})
				return
			end
			
      print(str:sub(1,30))
			error("unhandlable character "..peek().." on line "..line.." causing problems for lexing")
		end
		
		while peek() ~= "" do
			eat_noncode()
			
			next_token(q)
		end
		
		return q
	end
	
	t.parse = function(self, str)
    self.yet_to_eval = queue()
		local state = {}
		state.treetops = {}
		state.input = self:lex(str)
		state.closure = {}
    
    if self.config.preparse ~= nil and type(self.config.preparse) == "function" then
      state.input = self.config.preparse(state.input, queue())
    end
    
    --[[for _, rule in pairs(self.rules) do
      if rule.from == "_S" then
        self:add_to_closure(state.closure, {from=rule.from, into=rule.into,dot=0})
      end
    end]]
    self:add_to_closure(state.closure, {from="__S", into={"_S"}, dot=0})
    --we can't let this rule reduce any further because it creates infinite loops in some cases (like when you already have _S and there is more to parse)
		
		self.terminal_states = {}
		
		self.yet_to_eval:add(state)
		
		while not self.yet_to_eval:empty() do
			self:eval(self.yet_to_eval:get())
		end
		
		if #self.terminal_states == 0 then
			return false
		end
		if #self.terminal_states > 1 then
			error("string ambiguous under grammar!")
		end
		return self.terminal_states[1].treetops[1]
	end
	
	t.eval = function(self, state)
		--evaluate this state and enqueue children states to queue
		--self.state = self.yet_to_eval:get()
		self.state = state
		
		--sentinel case: input is empty and workspace has _S
		if state.input:empty() and #state.treetops == 1 and state.treetops[1].name == "_S" then
			table.insert(self.terminal_states, state)
			return
		end
		
		if not state.input:empty() then
			--attempt to follow edge on automaton
			self:follow_edge(state)
		end
		
		--apply reductions
		for _, rule in pairs(state.closure) do
			if rule.dot == #rule.into then --can only reduce if the dot is rightmost
				local offset = #state.treetops - #rule.into
				local valid = true
				for i, symbol in ipairs(rule.into) do
					valid = valid and state.treetops[offset+i].name == symbol
				end
				if valid then
					--the rule applies.
					self:reduce(state, rule, offset)
				end
			end
		end
	end
	
	--this should only be called if we know it can reduce with this rule
	--it will enqueue a new state to be evaluated
	t.reduce = function(self, state, rule, offset)
		--create a new state
		local new_state = {}
		new_state.input = state.input:copy()
		new_state.treetops = {}
		--copy old state's treetops, except for those now in the phrase
		local new_phrase = {}
		new_phrase.name = rule.from
		new_phrase.children = {}
		local ancestor_state = state
		for i, phrase in ipairs(state.treetops) do
			if i <= offset then
				new_state.treetops[i] = phrase
			else
        new_phrase.children[i-offset] = phrase
				--we'll take advantage of this opportunity to roll back the closure too
				ancestor_state = ancestor_state.parent
			end
		end
    
    --hack to make star-type phrases (T* -> T T*, T* -> T) work properly
    --specifically, so that instead of forming deep trees, that all generated phrases are on the same level
    --like {T, T, T, T, T} instead of {T, {T, {T, {T, {T}}}}}
    if rule.params and rule.params.flattenAfterwards == true then
      local new_children = {}
      for k, v in ipairs(new_phrase.children) do
        if v.name == new_phrase.name then
          for l, w in ipairs(v.children) do
            table.insert(new_children, w)
          end
        else
          table.insert(new_children, v)
        end
      end
      new_phrase.children = new_children
    end
    
		--insert the phrase into input
		new_state.input:unget(new_phrase)
		--roll back the closure
		new_state.closure = ancestor_state.closure
		new_state.parent = ancestor_state.parent
		
		--enqueue the created state
		self.yet_to_eval:add(new_state)
	end
	
	t.follow_edge = function(self, state)
		local new_state = {}
		new_state.input = state.input:copy()
		new_state.treetops = {}
		for i, phrase in ipairs(state.treetops) do
			new_state.treetops[i] = phrase
		end
		local symbol = new_state.input:get()
		table.insert(new_state.treetops, symbol)
		new_state.closure = {}
		new_state.parent = state
		for k, rule in pairs(state.closure) do
			if rule.dot < #rule.into and rule.into[rule.dot + 1] == symbol.name then
				self:add_to_closure(new_state.closure, {from=rule.from, into=rule.into, dot=rule.dot+1, params=rule.params})
			end
		end
		if #new_state.closure > 0 then
			self.yet_to_eval:add(new_state)
		end
	end
	
	t.add_to_closure = function(self, closure, rule)
		--make sure the closure does not already contain this rule
		for _, r in pairs(closure) do
			if r.from == rule.from and r.dot == rule.dot and #r.into == #rule.into then
				local identical = true
				for i, symbol in pairs(r.into) do
					identical = identical and rule.into[i] == symbol
				end
				if identical then
					return
				end
			end
		end
		--add it
		table.insert(closure, rule)
		--make sure this rule has a post-dot symbol
		if rule.dot == #rule.into then
			return
		end
		
		--add any rules from the post-dot symbol
		local postdot = rule.into[rule.dot+1]
		for _, r in pairs(self.rules) do
			if r.from == postdot then
				self:add_to_closure(closure, {from=r.from, into=r.into, dot=0, params=r.params})
			end
		end
	end
	
	t.load_state = function(self, new_state)
		local state = {}
		state.input = new_state.input:copy()
		state.treetops = {}
		for k, v in pairs(new_state.treetops) do
			state.treetops[k] = v
		end
		state.closure = new_state.closure
		
		return state
	end
  
  t.star = function(self, from, into)
    table.insert(self.rules, {from=from, into={from, into}, params={flattenAfterwards=true}})
    table.insert(self.rules, {from=from, into={into}})
  end
	
	t.gr = function(self, from, into)
		table.insert(self.rules, {from=from, into=into})
	end
	
	t.keyword = function(self, kw)
		self.lexables.keywords[kw] = kw
	end
	
	t.kw = t.keyword
	
	t.operator = function(self, op)
		if #op > 1 then
			-- we're going to break this up as multiple pieces joined by a grammar rule
			--there are some cases that this wouldn't work
			--it ignores grouping by whitespace for one: b --a is the same as b - -a
			--it also would break if an operator contains a regular name
			--for example, if "and" was registered as an operator (like basic)
			--the lexer may not recognize aandb as "a and b"
			
			local l = {}
			for char in op:gmatch(".") do
				self.lexables.operators[char] = char
				l[#l+1] = char
			end
			self:gr(op, l)
		else
			self.lexables.operators[op] = op
		end
	end
	
	t.op = t.operator
	
	return t
end

return parser
