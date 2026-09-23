--metaschema-aware json parser

local str = ""

local function peek()
  return str:sub(1,1)
end

local function eat()
  local toret = peek()
  str = str:sub(2)
  return toret
end

local function eatstr()
  local toret = ""
  while peek() ~= "" and peek() ~= '"' do
    toret = toret .. eat()
  end
  assert(eat() == '"')
  return toret
end

local function eatspace()
  while peek():match("%s") do eat() end
end

local function buildObject(name)
  local toret = {name=name, attr={}, children={}}
  eatspace()
  if peek() == "}" then
    return toret
  end
  while true do
    eatspace()
    assert(eat() == '"')
    local elem = eatstr()
    eatspace()
    assert(eat() == ":")
    if elem:sub(1, 1) == "@" then
      eatspace()
      assert(eat() == '"')
      toret.attr[elem:sub(2)] = eatstr()
    else
      eatspace()
      if peek() == "{" then
        eat()
        table.insert(toret.children, buildObject(elem))
      elseif peek() == '"' then
        eat()
        table.insert(toret.children, {name=elem, attr={}, children={eatstr()}})
      elseif peek() == "[" then
        eat()
        while true do --we don't need to make this a recursive function for our purposes
          --since in a json outlined by metaschema you can't have [[]]
          --all lists contain only objects, and are contained by objects
          eatspace()
          if peek() == '"' then
            eat()
            table.insert(toret.children, {name=elem, attr={}, children={eatstr()}})
          elseif peek() == "{" then
            eat()
            table.insert(toret.children, buildObject(elem))
          else
            error("character "..peek().." broke json parser")
          end
          eatspace()
          if peek() == "," then
            eat()
          elseif peek() == "]" then
            eat()
            break
          else
            error("character "..peek().." broke json parser")
          end
        end
      else
        error("character "..peek().." broke json parser")
      end
    end
    eatspace()
    if peek() == "," then
      eat()
    elseif peek() == "}" then
      eat()
      return toret
    else
      error("character "..peek().." broke json parser")
    end
  end
end

local function parse(instr)
  str = instr
  eatspace()
  assert(eat() == '"')
  local name = eatstr()
  eatspace()
  assert(eat() == ":")
  eatspace()
  local t = eat()
  if t == "{" then
    return buildObject(name)
  elseif t == '"' then
    return {name=name, attr={}, children={eatstr()}}
  end
  error("unrecognized character "..t.." broke json parser")
end

return {parse=function(self,instr) return parse(instr) end}