local metaschema = dofile("metaschema.lua")

local oscal = metaschema("../OSCAL/src/metaschema/oscal_complete_metaschema.xml")
local catalog = oscal:read("../oscal-content/examples/catalog/xml/basic_catalog.xml", "xml")
assert(catalog:isValid())

print(catalog["@uuid"])
print(catalog.group[1]["@id"])

print(catalog:toXML())
print(catalog:toJSON())

local f = io.open("testdocs/json_catalog.json", "w")
f:write(catalog:toJSON())
f:close()

local jsonCatalog = oscal:read("testdocs/json_catalog.json", "json")

print(jsonCatalog:toXML())

print(jsonCatalog["@uuid"])
print(jsonCatalog.group[1]["@id"])

oscal.resolve = dofile("profileresolver.lua")
local rp = oscal:resolve(oscal:read("../oscal-content/examples/profile/xml/basic_profile.xml", "xml"), "../oscal-content/examples/profile/xml/")
print("profile resolved")
print(rp:toXML())