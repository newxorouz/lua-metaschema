local str = ""

local function peek(n)
  n = n or 1
  return str:sub(1,n)
end

local function eat()
  local toret = peek()
  str = str:sub(2)
  return toret
end

local function eatstr()
  assert(eat() == '"')
  local toret = ""
  while peek() ~= "" and peek() ~= '"' do
    toret = toret .. eat()
  end
  assert(eat() == '"')
  return toret
end

local function eatname() --or number
  local toret = ""
  while peek():match("[%a_%d-:.]") do
    toret = toret .. eat()
  end
  return toret
end

local function eatdirective()
  if peek(4) == "<!--" then
    while peek(3) ~= "-->" do
      if peek() == "" then
        error("reached eof in comment")
      end
      eat()
    end
    eat()
    eat()
    eat()
    return
  end
  assert(eat()..eat() == "<!", "called eatdirective when it wasn't a directive!")
  while peek() ~= ">" do
    if peek(2) == "<!" then
      eatdirective()
    else
      eat()
    end
  end
  eat()
end

local function eatspace() --FIXME: also eats comments
  while peek():match("%s") do eat() end
  if peek(4) == "<!--" then
    eatdirective()
    eatspace()
  end
end

local function buildObject()
  --print(str) --make it appear in this scope for debugging
  assert(str~=nil) --same, but quieter
  assert(eat() == "<")
  local name = eatname()
  local toret = {name=name, attr={}, children={}}
  eatspace()
  
  --compile attrs
  while true do
    if peek(2) == "/>" then
      eat()
      eat()
      return toret
    elseif peek() == ">" then
      eat()
      break
    end
    local attrname = eatname()
    eatspace()
    assert(eat() == "=")
    eatspace()
    if peek() == '"' then
      toret.attr[attrname] = eatstr()
    else
      toret.attr[attrname] = eatname() --it's probably a number?
    end
    eatspace()
  end
  local str = ""
  while true do
    if peek(2) == "</" then
      if peek(#name+2):sub(3) == name then
        for i = 1, #name + 2 do
          eat(#name+2)
        end
        eatspace()
        assert(eat()==">")
        if str ~= "" then
          table.insert(toret.children, str)
        end
        return toret
      else
        --huh?
        error("bad xml ... open tag was "..name.." but closing tag was "..peek(#name+2):sub(3))
      end
    end
    if peek() == "<" then
      if peek(2) == "<!" then
        eatdirective()
      else
        if str ~= "" then
          table.insert(toret.children, str)
          str = ""
        end
        table.insert(toret.children, buildObject())
      end
    else
      str = str .. eat()
    end
  end
  
end

local function parse(instr)
  str = instr
  eatspace()
  while peek(2) == "<?" or peek(2) == "<!" do
    if peek(2) == "<!" then
      eatdirective()
      eatspace()
    else
      while peek(2) ~= "?>" do
        eat()
        if peek() == "" then
          error("unexpected eof in prolog")
        end
      end
      assert(eat()..eat()=="?>")
      eatspace()
    end
  end
  eatspace()
  return buildObject()
  --assert(str == "", "unrecognized character "..peek().." broke xml parser")
end

return {parse=function(self,instr) return parse(instr) end}