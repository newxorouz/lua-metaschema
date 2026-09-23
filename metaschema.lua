local xml = dofile("smartxml.lua")
local json = dofile("json.lua")
local queue = dofile("queue.lua")
local getWrapper = dofile("metaschemaobj.lua")


--input: metaschema documents of a specification (e.g. oscal specifications)
--returns: functions that takes in trees of the outlined specification and interprets them
-- by interpret i mean: validate and convert between formats
local function createMetaschemaEnvironment(metadefinition)
  local t = {}
  t.definitions = {}
  t.imported_docs = {}
  
  t.readMetaschemaFile = function(self, filename)
    local path_prefix = filename:match("(.*[/\\])")
    --TODO: what if it's a metaschema represented in JSON or YAML?
    local f = io.open(filename)
    assert(f~=nil, "file "..filename.." not found!")
    local tree = xml:parse(f:read("*all"))
    f:close()
    ---xml:parse should return the root object, which in the case of metaschema, is a METASCHEMA object
    local offset = 1
    while offset <= #tree.children do
      if tree.children[offset].name == "import" then
        local link = tree.children[offset].attr["href"]
        if not self.imported_docs[link] then --prevent cyclical dependencies from infinitely cycling
          self.imported_docs[link] = true
          local s,r = pcall(self.readMetaschemaFile,self, path_prefix..link)
          if not s then
            error(r.."\nwhile resolving "..link)
          end
        end
      elseif
            tree.children[offset].name == "define-assembly" or
            tree.children[offset].name == "define-field" or
            tree.children[offset].name == "define-flag" then --global definition
        local name = tree.children[offset].attr["name"]
        if self.definitions[name] ~= nil then
          print("WARNING: duplicate definition with name "..name)
        else
          self.definitions[name] = tree.children[offset]
        end
      end
      offset = offset + 1
    end
  end
  
  local removeStringsInAssemblies = {
    ["define-assembly"]=true,
    ["define-field"]=true,
    ["define-flag"]=true,
    assembly=true,
    field=true,
    flag=true,
    model=true,
    choice=true,
    ["choice-group"]=true
  }
  
  local renameGroupNames = {
    imports="import",
    definitions="object-type",
    flags="object-type",
    choices="object-type"
  }
  
  local remapDiscriminators = {
    assembly="define-assembly",
    field="define-field",
    flag="define-flag",
    ["assembly-ref"]="assembly",
    ["field-ref"]="field",
    ["flag-ref"]="flag"
  }
  
  t.normalizeMetaschema = function(self, definition)
    --normalize a metaschema:
    --remove text elements (all kinds of definitions are assemblies)
    --if the definition uses json-y wrapping, unwrap them to make it xml-y
    --(though this is partially done at the level of parsing json, so we just have to change the name to match)
    --this only targets a few items we are sure will be consistent for all version of metaschema
    --to avoid conflicting with future versions
    
    local discriminator = nil
    if renameGroupNames[definition.name] then
      definition.name = renameGroupNames[definition.name]
      discriminator = renameGroupNames[definition.name]
    end
    
    local new_children = {}
    for k, v in ipairs(definition.children) do
      if type(v) ~= "string" then --avoid text
        if v.name == discriminator then
          definition.name = remapDiscriminators[v.children[1]]
        elseif removeStringsInAssemblies[v.name] then
          table.insert(new_children, self:normalizeMetaschema(v))
        else
          table.insert(new_children, v) --still worth keeping, but we don't know if it's an assembly or field, so we can't normalize it
        end
      end
    end
    definition.children = new_children
    return definition
  end
  
  t.resolveName = function(self, declaration)
    local name = declaration.attr["name"] -- assume it's an inline def
    local definition = declaration
    if declaration.name == "assembly" or declaration.name == "field" or declaration.name == "flag" then --actually a reference
      name = declaration.attr["ref"]
      definition = self.definitions[name]
      
      --references can have a use-name
      --get the use-name if one is given
      for k, v in ipairs(definition.children) do
        if v.name == "use-name" then
          name = v.children[1]
        end
      end
      for k, v in ipairs(declaration.children) do
        if v.name == "use-name" then
          name = v.children[1]
        end
      end
    end
    
    --find the group-as element if present
    local groupAs = nil
    --we could probably combine this with the loop for finding use-name
    for k, v in ipairs(declaration.children) do
      if v.name == "group-as" then
        groupAs = v
      end
    end
    
    return name, definition, groupAs
  end
  
  t.interpretModelItem = function(self, q, fmt, instance, modelItem)
    --based off of the schema modelItem, add proper item(s) to instance
    --q: queue of children in the tree
    --fmt: format. xml or json. maybe yaml
    --instance: the instance we are building
    --modelItem: the piece of the schema we are analyzing
    --this function returns the number of items it found
    
    --all model items are choice-groups or degenerate choice-groups
    local expecting
    if modelItem.name == "choice" or modelItem.name == "choice-group" then
      expecting = modelItem.children
    else
      expecting = {modelItem} --assemblies and fields are like choice-groups with only one item
    end
    --crucially, expecting only contains assembly and field refs/defs now
    --next, get the cardinality
    local max, min
    if modelItem.name == "choice" then
      max = 1
      min = 1
    else
      max = tonumber(modelItem.attr["max-occurs"]) or modelItem.attr["max-occurs"] or 1
      min = tonumber(modelItem.attr["min-occurs"]) or 0
    end
    
    local count = 0
    while not q:empty() and (max == "unbounded" or count < max) do
      local found = false
      local choiceSkippable = false
      for m, declaration in ipairs(expecting) do
        --for everything in the choice-group (possibly only one thing)
        local name, definition, groupAs = self:resolveName(declaration)
        
        --items in a choice can have a cardinality
        local submax = 1
        local submin = 1
        --choice must find at least one of its options, however those options could have a min of 0 (and thus be optional)
        if modelItem.name == "choice" then
          submax = tonumber(declaration.attr["max-occurs"]) or declaration.attr["max-occurs"] or 1
          submin = tonumber(declaration.attr["min-occurs"]) or 0
        end
        local subcount = 0
        
        if submin == 0 then
          min = 0 --it's fine to find nothing in the choice
        end
        
        --handle group-as
        if groupAs ~= nil then
          if fmt == "json" then
            name = groupAs.attr["name"]
          else
            if groupAs.attr["in-xml"] == "GROUPED" then
              name = groupAs.attr
            end
          end
        end
        
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
          --assemblies and fields are handled the same
          table.insert(instance.children, self:createInstance(gotten_item, fmt, definition))
          
          gotten_item = q:get()
        end
        
        if found and modelItem.name == "choice" then
          assert(subcount >= submin, "choice tried to find "..name.." with minimum cardinality "..submin.." but only found "..subcount)
          count = count + 1
        else
          count = count + subcount
        end
        
        --if we ended on a non-nil, put it back for the next guy
        if gotten_item then
          q:unget(gotten_item)
        end
      end
      if not found then
        if count < min then
          local str = ""
          for _, v in pairs(expecting) do
            str = str..", "..(v.attr["name"] or v.attr["ref"])
          end
          error("expected "..min.." items ("..str:sub(2)..") but found "..count)
        end
        assert(count >= min, "required items not found")
        return count
      end
    end
    return count
  end
  
  --walk through a schema and point out where each model item starts while doing so
  t.walkModelItems = function(self, tree)
    local model = nil
    for _, v in ipairs(tree.schema.children) do
      if v.name == "model" then
        model = v
      end
    end
    
  end
  
  --we're going to put this here, and not with the implementation of an instance
  --we're doing that because this has to be aware of how the schema works internally
  --(specifically, aware that schemas are not handled as instances but as an intermediate format more like a parse tree)
  
  --usage: for declaration, entry in lang:walkByModel(instance._schema.model, instance) do...
  -- it will go through every child of instance
  -- and give the declaration that yielded it alongside it
  t.walkByModel = function(self, tree)
    local model = nil
    for _, v in ipairs(tree.schema.children) do
      if v.name == "model" then
        model = v
      end
    end
    
    local q = queue()
    for _, v in ipairs(tree.children) do
      q:add(v)
    end
    
    local toret = queue()
    
    for _, modelItem in ipairs(model.children) do
      --based off of the schema modelItem, add proper item(s) to instance
      --q: queue of children in the tree
      --fmt: format. xml or json. maybe yaml
      --instance: the instance we are building
      --modelItem: the piece of the schema we are analyzing
      --this function returns the number of items it found
      
      --all model items are choice-groups or degenerate choice-groups
      local expecting
      if modelItem.name == "choice" or modelItem.name == "choice-group" then
        expecting = modelItem.children
      else
        expecting = {modelItem} --assemblies and fields are like choice-groups with only one item
      end
      --crucially, expecting only contains assembly and field refs/defs now
      --next, get the cardinality
      local max, min
      if modelItem.name == "choice" then
        max = 1
        min = 1
      else
        max = tonumber(modelItem.attr["max-occurs"]) or modelItem.attr["max-occurs"] or 1
        min = tonumber(modelItem.attr["min-occurs"]) or 0
      end
      
      local count = 0
      while not q:empty() and (max == "unbounded" or count < max) do
        local found = false
        local choiceSkippable = false
        for m, declaration in ipairs(expecting) do
          --for everything in the choice-group (possibly only one thing)
          local name, definition, groupAs = self:resolveName(declaration)
          
          --items in a choice can have a cardinality
          local submax = 1
          local submin = 1
          --choice must find at least one of its options, however those options could have a min of 0 (and thus be optional)
          if modelItem.name == "choice" then
            submax = tonumber(declaration.attr["max-occurs"]) or declaration.attr["max-occurs"] or 1
            submin = tonumber(declaration.attr["min-occurs"]) or 0
          end
          local subcount = 0
          
          if submin == 0 then
            min = 0 --it's fine to find nothing in the choice
          end
          
          --handle group-as
          if groupAs ~= nil then
            if fmt == "json" then
              --name = groupAs.attr["name"]
            else
              if groupAs.attr["in-xml"] == "GROUPED" then
                --name = groupAs.attr
              end
            end
          end
          
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
          local gotten_name = gotten_item.name
          if not gotten_name or #gotten_name == 0 then
            --this isn't a string, it's an IndexResults. who decided to give this a metamethod? smh
            gotten_name = gotten_item._rawdata.schema.attr["name"] --what a mouthful
          end
          while (submax == "unbounded" or subcount < submax) and gotten_name == name do
            --success! we got an item!
            subcount = subcount + 1
            found = true
            
            toret:add({modelItem, gotten_item})
            
            gotten_item = q:get()
            if not gotten_item then
              break
            end
            gotten_name = gotten_item.name
            if #gotten_item.name == 0 then
              gotten_name = gotten_item._rawdata.schema.attr["name"] --what a mouthful
            end
          end
          
          if found and modelItem.name == "choice" then
            assert(subcount >= submin, "choice tried to find "..name.." with minimum cardinality "..submin.." but only found "..subcount)
            count = count + 1
          else
            count = count + subcount
          end
          
          --if we ended on a non-nil, put it back for the next guy
          if gotten_item then
            q:unget(gotten_item)
          end
        end
        if not found then
          if count < min then
            local str = ""
            for _, v in pairs(expecting) do
              str = str..", "..(v.attr["name"] or v.attr["ref"])
            end
            error("expected "..min.." items ("..str:sub(2)..") but found "..count)
          end
          assert(count >= min, "required items not found")
          break
        end
      end
    end
    
    return function()
      local pair = toret:get()
      if not pair then return end
      return pair[1], pair[2]
    end
  end
  
  local typeDefaults = {
    string=function() return "" end,
    base64=function() return "" end,
    boolean=function() return "yes" end,
    date=function() return "" end,
    uuid=function() return "" end
  } --TODO: extend for all types, generate uuids and timestamps correctly
  
  t.new = function(self, schema)
    if type(schema) == "string" then
      schema = self.definitions[schema]
    end
    local instance = {}
    instance.schema = schema
    instance.flags = {}
    instance.children = {}
    if schema.name == "define-field" then
      instance.children[1] = ""
    end
    
    for _, schemaItem in ipairs(schema.children) do
      if schemaItem.name == "define-flag" or schemaItem.name == "flag" then
        local name, def = self:resolveName(schemaItem)
        if schemaItem.attr["required"] then
          if schemaItem.attr["default"] then
            instance.flags[name] = schemaItem.attr["default"]
          elseif def.attr["default"] then
            instance.flags[name] = def.attr["default"]
          else
            --make assumption about what this should be populated with based off of type?
            local t = def.attr["as-type-simple"] or "string"
            if not typeDefaults[t] then
              instance.flags[name] = ""
            else
              instance.flags[name] = typeDefaults[t]()
            end
          end
        end
      end
      if schemaItem.name == "model" then
        for _, modelItem in ipairs(schemaItem.children) do
          local min
          if modelItem.name == "choice" then
            for _, choiceItem in ipairs(modelItem.children) do
              modelItem = choiceItem
              min = tonumber(modelItem.attr["min-occurs"]) or 0
              if min == 0 then
                break
              end
            end
          else
            min = tonumber(modelItem.attr["min-occurs"]) or 0
          end
          local name, def = self:resolveName(modelItem)
          if min ~= 0 then
            --TODO: i'm assuming min is therefore one, but it could be more
            if modelItem.name == "choice-group" then
              error("TODO: choice group with minimum > 0")
            else
              table.insert(instance.children, self:new(def))
            end
          end
        end
      end
    end
    
    return self.wrapper(instance)
  end
  
  t.createInstance = function(self, tree, fmt, schema)
    schema = schema or self.definitions[tree.name]
    assert(schema ~= nil)
    
    local instance = {}
    instance.schema = schema
    instance.flags = {}
    instance.children = {}
    
    if schema.name == "define-field" then
      instance.children = tree.children
    end
    
    for _, schemaItem in ipairs(schema.children) do
      --bear mind that schemaItem could be a string, because we are handling XML directly (not metaschema instances!)
      --we can't remove them here because it would break ipairs
      if schemaItem.name == "define-flag" or schemaItem.name == "flag" then
        local declaration = schemaItem
        local flagName, definition = self:resolveName(declaration)
        if tree.attr[flagName] ~= nil then
          instance.flags[flagName] = tree.attr[flagName]
        elseif declaration.attr["required"] then
          error("required flag "..flagName.." is not present")
        end
      end
      if schemaItem.name == "model" then
        local q = queue()
        for _, v in ipairs(tree.children) do
          q:add(v)
        end
        
        for _, modelItem in pairs(schemaItem.children) do
          self:interpretModelItem(q, fmt, instance, modelItem)
        end
      end
    end
    --TODO?: wrap in something with nice metamethods
    return self.wrapper(instance)
  end
  
  t.read = function(self, filename, fmt)
    if not fmt then
      fmt = filename:sub(-4)
      if fmt ~= "json" then
        fmt = "xml"
      end
    end
    local f = io.open(filename)
    if not f then
      error("file "..filename.." not found")
    end
    local tree = nil
    if fmt == "xml" then
      tree = xml:parse(f:read("*all"))
    elseif fmt == "json" then
      tree = json:parse(f:read("*all"))
    end
    f:close()
    
    return self:createInstance(tree, fmt)
  end
  
  t:readMetaschemaFile(metadefinition)
  
  --beautify definitions by removing unneeded strings
  --also, if the definition is json, let's remove group-as
  for k, v in pairs(t.definitions) do
    t.definitions[k] = t:normalizeMetaschema(v) --strictly speaking, the assignment is not necessary
  end
  t.wrapper = getWrapper(t)
  return t
end

return createMetaschemaEnvironment