local queue = dofile("queue.lua")

local MetaschemaObject = {}

local language = {}

local IndexResults = {}

local function bindAsMetaschemaObject(object)
  return setmetatable({_rawdata=object}, MetaschemaObject)
end

local function init(lang)
  language = lang
  return bindAsMetaschemaObject
end

function IndexResults:__concat(b)
  local toret = setmetatable({}, IndexResults)
  for _, v in ipairs(self) do
    table.insert(toret, v)
  end
  for _, v in ipairs(b) do
    table.insert(toret, v)
  end
  return toret
end

function IndexResults:asIndexResults()
  return self
end

function IndexResults:__index(key)
  --this means that it's not already present in the IndexResults. so it's not a number
  if IndexResults[key] ~= nil then
    return IndexResults[key]
  end
  if #self == 1 then --if we only have one item, expose that item
    return self[1][key]
  end
  --otherwise, we have multiple items
  --index them each and aggregate the results
  local toret = setmetatable({}, IndexResults)
  for _, item in ipairs(self) do
    --we're preserving order
    local gotten = item[key]:asIndexResults()
    for _, entry in ipairs(gotten) do
      table.insert(toret, entry)
    end
  end
  return toret
end

function MetaschemaObject:__index(key)
  if MetaschemaObject[key] ~= nil then
    return MetaschemaObject[key]
  end
  if key:sub(1, 1) == "@" then
    --it's an attribute/flag
    return self._rawdata.flags[key:sub(2)]
  end
  if self._rawdata.schema.name == "define-field" then
    return setmetatable({}, IndexResults) --no indexing fields outside of flags
  end
  local toret = setmetatable({}, IndexResults)
  for _, v in ipairs(self._rawdata.children) do
    if v._rawdata.schema.attr.name == key then
      table.insert(toret, v)
    end
  end
  --[[if #toret == 1 then
    return toret[1]
  end]]
  --[[if #toret == 0 then
    return nil
  end]]
  return toret
end

function MetaschemaObject:__newindex(key, value)
  if key:sub(1, 1) == "@" then
    --TODO: check that given key is really the name of a flag
    --TODO: check that the value is permissible for this kind of flag
    self._rawdata.flags[key:sub(2)] = value
    return
  end
  if self._rawdata.schema.name == "define-field" then
    --not exactly clear what this should mean
    return
  end
  local index = 1
  local singular = true
  for declaration, i in language:walkModelItems(self._rawdata) do
    local name = language:resolveName(declaration)
    local max = tonumber(declaration.attr["max-occurs"]) or declaration.attr["max-occurs"] or 1
    if name == key then
      index = i
      singular = (max == 1)
    end
  end
  if singular then
    
  else
    table.insert(index + 1, value)
  end
end

--MetaschemaObject.__concat = IndexResults.__concat --this is not great

--[[function MetaschemaObject:__ipairs()
  --this is deprecated in modern Lua
  --but i'll include it for completeness nonetheless
  --should behave like IndexResults
  return function(arr, index)
      if index == 1 then
        return index+1, self
      end
    end, self, 1
  --this line is a little hard to read. basically, return key 1, self, if and only if the loop prompts us for the first index. otherwise? nil.
end]]

--[[function MetaschemaObject:__len()
  return 1 --this was likely going to be the case anyways
  --but i've included for the sake of clarity
  --this way, it is consistent with the interface of IndexResults
end]]

--[[function MetaschemaObject:__tostring()
  if self._rawdata.schema.name == "define-field" then
    --TODO: actually properly form together the string value
    return self._rawdata.children[1]
  else
    if true then --verbose tostring...
      local toret = "{"
      for k, v in pairs(self._rawdata.flags) do
        toret=toret..k..' = "'..v..'",'
      end
      for k, v in pairs(self._rawdata.children) do
        toret=toret..tostring(v)..","
      end
      return toret:sub(1, -2).."}"
    end
    return self._rawdata.schema.attr["name"]
  end
end]]

-- in order to eventually stop using __ipairs, __len, __concat, etc.
function MetaschemaObject:asIndexResults()
  return setmetatable({self}, IndexResults)
end

function MetaschemaObject:anychildHas(name)
  if self._rawdata.schema.name == "define-field" then
    return self[name]
  end
  local toret = self[name]
  for k, v in pairs(self._rawdata.children) do
    toret = toret .. v:anychildHas(name)
  end
  return toret
end

function MetaschemaObject:toXML()
  local str = "<"
  local name = self._rawdata.schema.attr["name"] or self._rawdata.schema.attr["ref"]
  --TODO: use-name & root-name
  str = str..name
  for k, v in pairs(self._rawdata.flags) do
    str = str.." "..k.."="..'"'..v..'"'
  end
  if #self._rawdata.children == 0 then
    return str.."/>"
  end
  str = str..">"
  if self._rawdata.schema.name=="define-field" or self._rawdata.schema.name=="field" then
    str = str .. self:toMarkup()
    return str.."</"..name..">"
  end
  for declaration, child in language:walkByModel(self._rawdata) do
    str = str..child:toXML()
  end
  return str.."</"..name..">"
end

function MetaschemaObject:toJSON(declaration)
  local schema = self._rawdata.schema
  local flags = self._rawdata.flags
  local children = self._rawdata.children
  
  declaration = declaration or schema
  
  local str = ""
  
  local name, _, groupAs = language:resolveName(declaration)
  --dispense with the second result because we already have schema
  
  if schema.name == "define-field" then
    return '"'..name..'":"'..self:toMarkdown()..'"'
  end
  
  if not groupAs then
    str = str .. '"'..name .. '":{'
  else
    str = str .. "{"
  end
  for k, v in pairs(flags) do
    str = str..'"@'..k..'":"'..v..'",'
  end
  local addedGroupLabels = {}
  for declaration, v in language:walkByModel(self._rawdata) do
    name, schema, groupAs = language:resolveName(declaration)
    if groupAs then
      if not addedGroupLabels[groupAs.attr["name"]] then
        addedGroupLabels[groupAs.attr["name"]] = true
        str = str ..'"'.. groupAs.attr["name"]..'":['..v:toJSON(declaration).."],"
      else
        str = str:sub(1, -3) ..",".. v:toJSON(declaration).."],"
      end
    else
      str = str .. v:toJSON(declaration) .. ","
    end
  end
  
  str = str:sub(1, -2) --remove last comma
  str = str.."}"
  return str
end

--converts the value of a field to a string of markdown
function MetaschemaObject:toMarkdown(tag)
  if not self._rawdata.schema.name == "define-field" then
    return
  end
  tag = tag or self._rawdata
  if #tag.children == 1 then
    return tag.children[1]
  end
  local str = ""
  for i, v in ipairs(tag.children) do
    if type(v) == "string" then
      str = str .. v
    else
      --markup tag
      --TODO: check type of markup tag and insert  appropriate thing
      str = str .. self:toMarkdown(v)
    end
  end
  return str
end

--converts the value of a field to a string of markup
function MetaschemaObject:toMarkup(tag)
  if not self._rawdata.schema.name == "define-field" then
    return
  end
  tag = tag or self._rawdata
  local str = ""
  for i, v in ipairs(tag.children) do
    if type(v) == "string" then
      str = str .. v
    else
      --markup tag
      --TODO: check type. see toMarkdown
      str = str .. self:toMarkup(v)
    end
  end
  return str
end

function MetaschemaObject:isValid()
  --TODO: return information about how it fails rather than simply indicating that it does
  local schema = self._rawdata.schema
  local flags = self._rawdata.flags
  
  if schema.name == "define-field" then
    --TODO: check value is conformant to type
  end
  
  --first, check that the instance has all things specified in the schema
  for k, schemaItem in ipairs(schema.children) do
    if schemaItem.name == "define-flag" or schemaItem.name == "flag" then
      local name, definition = language:resolveName(schemaItem)
      if schemaItem.attr["required"] and flags[name] == nil then
        return false
      end
      --TODO: check value is conformant to type
    end
    if schemaItem.name == "model" then
      --[[--convert the elements of the instance to a queue
      local q = queue()
      for l, v in ipairs(children) do
        q:add(v)
      end
      
      --each item in the model is either a choice group or a degenerate case of the choice-group (with one choice or cardinality 1-1)
      for l, modelItem in ipairs(schemaItem.children) do
        local expecting = nil --all things we expect to see next in the queue
        if modelItem.name == "choice" or modelItem.name == "choice-group" then
          expecting = modelItem.children
        else --assembly or field
          expecting = {modelItem}
        end
        --expecting now only contains assembly & field refs/defs
        local max, min
        if modelItem.name == "choice" then --choice is a degenerate choice-group with cardinality between 1 and 1 (so not a group)
          max = 1
          min = 1
        else
          max = tonumber(modelItem.attr["max-occurs"]) or modelItem.attr["max-occurs"] or 1
          min = tonumber(modelItem.attr["min-occurs"]) or 0
        end
        
        local count = 0
        while not q:empty() and (max == "unbounded" or count < max) do
          local found = false
          for m, declaration in ipairs(expecting) do
            --for everything in the choice-group (possibly only one thing)
            local name, definition = language:resolveName(declaration)
            
            local submax = 1
            local submin = 1
            if modelItem.name == "choice" then
              submax = tonumber(declaration.attr["max-occurs"]) or declaration.attr["max-occurs"] or 1
              submin = tonumber(declaration.attr["min-occurs"]) or 0
            end
            local subcount = 0
            
            --okay! we know everything about what we are hoping for, let's see if it's right!
            local gotten_item = q:get()
            while type(gotten_item) == "string" do
              --boo, hiss! strings in our object! we're analyzing a model so this is an assembly
              --get rid of it
              gotten_item = q:get()
            end
            if not gotten_item then --we ran out of stuff to get
              break
            end
            while (submax == "unbounded" or subcount < submax) and gotten_item.name == name do
              --success! we got an item!
              subcount = subcount + 1
              found = true
              if not gotten_item:isValid() then
                return false
              end
            end
            
            if modelItem.name == "choice" then
              assert(subcount >= submin, "choice tried to find "..name.." with minimum cardinality "..submin.." but only found "..subcount)
              count = count + 1
            else
              count = count + subcount
            --end
            
            if gotten_item then
              --not what we were hoping
              q:unget(gotten_item)
            end
          end
          if not found then
            break
          end
        end
      end]]
      for _, modelItem in ipairs(schemaItem.children) do
        if modelItem.name == "choice" then
          local found = false
          for _, choiceItem in ipairs(modelItem.children) do
            local name = choiceItem.attr["name"] or choiceItem.attr["ref"]
            local max = tonumber(choiceItem.attr["max-occurs"]) or choiceItem.attr["max-occurs"] or 1
            local min = tonumber(choiceItem.attr["min-occurs"]) or 0
            if min == 0 then found = true end
            local results = self[name]
            if #results > 0 then
              if #results < min then
                return false
              end
              if max ~= "unbounded" and #results > max then
                return false
              end
              for _, v in ipairs(results) do
                if not v:isValid() then
                  return false
                end
              end
            end
          end
          if not found then
            return false
          end
        else
          local name = modelItem.attr["name"] or modelItem.attr["ref"]
          local max = tonumber(modelItem.attr["max-occurs"]) or modelItem.attr["max-occurs"] or 1
          local min = tonumber(modelItem.attr["min-occurs"]) or 0
          
          local results = {}
          if modelItem.name == "choice-group" then
            for _, choiceItem in ipairs(modelItem.children) do
              results = results..self[choiceItem.attr["name"] or choiceItem.attr["ref"]]
            end
          else
            results = self[name]
          end
          if #results < min then
            return false
          end
          if max ~= "unbounded" and #results > max then
            return false
          end
          for _, v in ipairs(results) do --if the result was single, this should still work
            --because ipairs will try results[1] (works, see __index), but then results[2] should return nil
            if not v:isValid() then
              return false
            end
          end
        end
      end
    end
    if schemaItem.name == "constraint" then
      --TODO: evaluate constraints
    end
  end
  
  return true
end

return init