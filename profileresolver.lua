local function convertRegex(re)
  local luaRe = re:gsub("%*%.", {
      ["."]="%.",
      ["*"]="."})
  return luaRe
end

local function resolve(oscal, profile, fromDir)
  fromDir = fromDir or ""
  local gottenControls = {}
  for _, v in ipairs(profile.import) do
    local catalogOrProfile = oscal:read(fromDir..v["@href"])
    local catalog
    if catalogOrProfile._rawdata.schema.attr["name"] == "catalog" then
      catalog = catalogOrProfile
    else
      catalog = self:resolve(catalogOrProfile)
    end
    local thisCatalogControls = {}
    for _, w in ipairs(catalog:anychildHas("control")) do
      --TODO: combine directive
      thisCatalogControls[w["@id"]] = w
    end
    local includeCtls = v["select-control-by-id"]
    for _, w in ipairs(includeCtls["with-id"]) do
      table.insert(gottenControls, thisCatalogControls[tostring(w)])
    end
    for _, w in ipairs(includeCtls["matching"]) do
      --TODO: check that this works
      for k, v in pairs(thisCatalogControls) do
        if k:match(convertRegex(w["@pattern"])) then
          table.insert(gottenControls, v)
        end
      end
    end
  end
  
  local toret = oscal:new("catalog")
  
  --TODO: merge directive
  --this only does flatten
  for k, v in pairs(gottenControls) do
    --toret.control = v
    table.insert(toret._rawdata.children, v)
  end
  
  return toret
end

return resolve