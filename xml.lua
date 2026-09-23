local xml = dofile("parser.lua")()

xml:configure("comment", {"<!--", "-->"})
xml:configure("namemiddle", "[^%a_%d-:]")
xml:configure("enableText", true)
xml:configure("textLDelim", ">")
xml:configure("textRDelim", "<")

xml:gr("_S", {"Prolog*", "Element"})
xml:gr("_S", {"Element"})

xml:star("Prolog*", "Prolog")
xml:star("Directive*", "Directive")
xml:gr("Prolog", {"Prolog", "_TEXT"})--for eating newlines
xml:gr("Directive", {"Directive", "_TEXT"}) --unfortunately this breaks the flattening of the stars

xml:gr("Prolog", {"<?", "_NAME", "Attribute*", "?>"})
xml:gr("Prolog", {"<?", "_NAME", "?>"})

xml:gr("Element", {"OpenTag", "CloseTag"})
xml:gr("Element", {"OpenTag", "Content*", "CloseTag"})
xml:gr("Element", {"CompactTag"})

--[[xml:gr("Content*", {"Content*", "Content"})
xml:gr("Content*", {"Content"})
xml:gr("Content", {"Element"})
xml:gr("Content", {"_TEXT"})]]

xml:star("Content*", "Element")
xml:star("Content*", "_TEXT")

xml:gr("OpenTag", {"<", "_NAME", "Attribute*", ">"})
xml:gr("OpenTag", {"<", "_NAME", ">"})
--[[xml:gr("Attribute*", {"Attribute*", "Attribute"})
xml:gr("Attribute*", {"Attribute"})]]--
xml:star("Attribute*", "Attribute")
xml:gr("Attribute", {"_NAME", "=", "_NUMBER"})
xml:gr("Attribute", {"_NAME", "=", "_STRING"})
xml:gr("CloseTag", {"</", "_NAME", ">"})

xml:gr("CompactTag", {"<", "_NAME", "Attribute*", "/>"})
xml:gr("CompactTag", {"<", "_NAME", "/>"})

xml:op("<")
xml:op(">")
xml:op("<?")
xml:op("?>")
xml:op("</")
xml:op("/>")
xml:op("=")


--this part is a little rough
--the parser includes "prelex" and "preparse" functions specifically for this
local function prelex(str)
  local newstr = ""
  
  local function advance()
    local char = str:sub(1,1)
    str = str:sub(2)
    return char
  end
  
  local function handleDirective()
    while str:sub(1,1) ~= ">" do
      if str:sub(1,2) == "<!" then
        advance()
        advance()
        handleDirective()
      else
        advance()
      end
    end
    advance()
  end
  
  while str ~= "" do
    if str:sub(1,2) == "<!" and str:sub(1,4) ~= "<!--" then
      advance()
      advance()
      handleDirective()
    else
      newstr = newstr .. advance()
    end
  end
  return newstr
end

local function preparse(oldq, newq)
  local count = 0
  while not oldq:empty() do
    local item = oldq:get()
    if item.name == "<" then
      count = count + 1
      newq:add(item)
      item = oldq:get()
      if item.name == "/" then
        count = count - 2
      end
    elseif item.name == "/" then
      count = count - 1
    elseif item.name == "?" then
      count = count - 1
    end
    if count ~= 0 or item.name ~= "_TEXT" then
      newq:add(item)
    end
  end
  return newq
end

xml:configure("prelex", prelex)
xml:configure("preparse", preparse)

local function xml_build_element(node)
  assert(node.name == "Element")
  local element = {}
  local otag = node.children[1]
  element.name = otag.children[2].value
  if #node.children > 1 then
    --i.e. not compact node
    local ctag = node.children[#node.children]
    assert(otag.children[2].value == ctag.children[2].value)
  end
  element.attr = {}
  if #otag.children == 4 then
  --i.e. there are attributes
    local attrs = otag.children[3].children --children of the Attribute* node
    for _, attr in pairs(attrs) do
      local attrname = attr.children[1].value
      local attrv = attr.children[3].value
      element.attr[attrname] = attrv
    end
  end
  element.children = {}
  if #node.children == 3 then
    --there is subelements/text
    for i, child in ipairs(node.children[2].children) do
      if child.name == "Element" then
        element.children[i] = xml_build_element(child)
      elseif child.name == "_TEXT" then
        element.children[i] = child.value
      end
    end
  end
  
  return element
end

local function xml_build_tree(str)
  local tree = xml:parse(str)
  assert(tree.name == "_S")
  local root = tree.children[#tree.children]
  return xml_build_element(root)
end

local wrapped_xml = {}

function wrapped_xml:parse(str)
  return xml_build_tree(str)
end

return wrapped_xml
