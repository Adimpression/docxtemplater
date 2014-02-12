root= global ? window
env= if global? then 'node' else 'browser'

#This is an abstract class, DocXTemplater is an example of inherited class

XmlTemplater =  class XmlTemplater #abstract class !!
	constructor: (content="",options={}) ->
		@tagX='' #TagX represents the name of the tag that contains text. For example, in docx, @tagX='w:t'
		@currentClass=XmlTemplater #This is used because tags are recursive, so the class needs to be able to instanciate an object of the same class. I created a variable so you don't have to Override all functions relative to recursivity
		@Tags= if options.Tags? then options.Tags else {}
		@DocxGen= if options.DocxGen? then options.DocxGen else null
		@intelligentTagging=if options.intelligentTagging? then options.intelligentTagging else off
		@scopePath=if options.scopePath? then options.scopePath else []
		@usedTags=if options.usedTags? then options.usedTags else {}
		@imageId=if options.imageId? then options.imageId else 0
		@currentScope=@Tags
		@templaterState= new TemplaterState
	load: (@content) ->
		@templaterState.matches = @_getFullTextMatchesFromData()
		@templaterState.charactersAdded= (0 for i in [0...@templaterState.matches.length])
		@handleRecursiveCase()
	getValueFromScope: (tag,scope) ->
		@useTag(tag)
		if scope[tag]?
			content= DocUtils.encode_utf8 scope[tag]
		else
			content= "undefined"
			@DocxGen.logUndefined(tag,scope)
		if content.indexOf('{')!=-1 or content.indexOf('}')!=-1
			throw "You can't enter { or  } inside the content of a variable"
		content
	getListXmlElements: (text,start=0,end=text.length-1) ->
		###
		get the different closing and opening tags between two texts (doesn't take into account tags that are opened then closed (those that are closed then opened are returned)):
		returns:[{"tag":"</w:r>","offset":13},{"tag":"</w:p>","offset":265},{"tag":"</w:tc>","offset":271},{"tag":"<w:tc>","offset":828},{"tag":"<w:p>","offset":883},{"tag":"<w:r>","offset":1483}]
		###
		tags= DocUtils.preg_match_all("<(\/?[^/> ]+)([^>]*)>",text.substr(start,end)) #getThemAll (the opening and closing tags)!
		result=[]
		for tag,i in tags
			if tag[1][0]=='/' #closing tag
				justOpened= false
				if result.length>0
					lastTag= result[result.length-1]
					innerLastTag= lastTag.tag.substr(1,lastTag.tag.length-2)
					innerCurrentTag= tag[1].substr(1)
					if innerLastTag==innerCurrentTag then justOpened= true #tag was just opened
				if justOpened then result.pop() else result.push {tag:'<'+tag[1]+'>',offset:tag.offset}
			else if tag[2][tag[2].length-1]=='/' #open/closing tag aren't taken into account(for example <w:style/>)
			else	#opening tag
				result.push {tag:'<'+tag[1]+'>',offset:tag.offset}
		result
	calcScopeDifference: (text,start=0,end=text.length-1) -> #it returns the difference between two scopes, ie simplifyes closes and opens. If it is not null, it means that the beginning is for example in a table, and the second one is not. If you hard copy this text, the XML will  break
		scope= @getListXmlElements text,start,end
		while(1)
			if (scope.length<=1) #if scope.length==1, then they can't be an opeining and closing tag
				break;
			if ((scope[0]).tag.substr(2)==(scope[scope.length-1]).tag.substr(1)) #if the first closing is the same than the last opening, ie: [</tag>,...,<tag>]
				scope.pop() #remove both the first and the last one
				scope.shift()
			else break;
		scope
	getFullText:() ->
		@templaterState.matches= @_getFullTextMatchesFromData() #get everything that is between <w:t>
		output= (match[2] for match in @templaterState.matches) #get only the text
		DocUtils.decode_utf8(output.join("")) #join it
	_getFullTextMatchesFromData: () ->
		@templaterState.matches= DocUtils.preg_match_all("(<#{@tagX}[^>]*>)([^<>]*)?</#{@tagX}>",@content)
	calcInnerTextScope: (text,start,end,tag) -> #tag: w:t
		endTag= text.indexOf('</'+tag+'>',end)
		if endTag==-1 then throw "can't find endTag #{endTag}"
		endTag+=('</'+tag+'>').length
		startTag = Math.max text.lastIndexOf('<'+tag+'>',start), text.lastIndexOf('<'+tag+' ',start)
		if startTag==-1 then throw "can't find startTag"
		{"text":text.substr(startTag,endTag-startTag),startTag,endTag}
	findOuterTagsContent: () ->
		start = @templaterState.calcStartTag @templaterState.loopOpen
		end= @templaterState.calcEndTag @templaterState.loopClose
		{content:@content.substr(start,end-start),start,end}
	findInnerTagsContent: () ->
		start= @templaterState.calcEndTag @templaterState.loopOpen
		end= @templaterState.calcStartTag @templaterState.loopClose
		{content:@content.substr(start,end-start),start,end}
	toJson: () ->
		Tags:DocUtils.clone @Tags
		DocxGen:@DocxGen
		intelligentTagging:DocUtils.clone @intelligentTagging
		scopePath:DocUtils.clone @scopePath
		usedTags:@usedTags
		localImageCreator:@localImageCreator
		imageId:@imageId
	forLoop: (innerTagsContent="",outerTagsContent="") ->
		###
			<w:t>{#forTag} blabla</w:t>
			Blabla1
			Blabla2
			<w:t>{/forTag}</w:t>

			Let innerTagsContent be what is in between the first closing bracket and the second opening bracket
			Let outerTagsContent what is in between the first opening tag {# and the last closing tag

			innerTagsContent=</w:t>
			Blabla1
			Blabla2
			<w:t>

			outerTagsContent={#forTag}</w:t>
			Blabla1
			Blabla2
			<w:t>{/forTag}

			We replace outerTagsContent by n*innerTagsContent, n is equal to the length of the array in scope forTag
			<w:t>subContent subContent subContent</w:t>
		###
		if innerTagsContent=="" and outerTagsContent==""
			outerTagsContent= @findOuterTagsContent().content
			innerTagsContent= @findInnerTagsContent().content

			if outerTagsContent[0]!='{' or outerTagsContent.indexOf('{')==-1 or outerTagsContent.indexOf('/')==-1 or outerTagsContent.indexOf('}')==-1 or outerTagsContent.indexOf('#')==-1 then throw "no {,#,/ or } found in outerTagsContent: #{outerTagsContent}"

		if @currentScope[@templaterState.loopOpen.tag]?
			# if then throw '{#'+@templaterState.loopOpen.tag+"}should be an object (it is a #{typeof @currentScope[@templaterState.loopOpen.tag]})"
			subScope= @currentScope[@templaterState.loopOpen.tag] if typeof @currentScope[@templaterState.loopOpen.tag]=='object'
			subScope= true if @currentScope[@templaterState.loopOpen.tag]=='true'
			subScope= false if @currentScope[@templaterState.loopOpen.tag]=='false'
			newContent= "";

			if typeof subScope == 'object'
				for scope,i in @currentScope[@templaterState.loopOpen.tag]
					options= @toJson()
					options.Tags=scope
					options.scopePath= options.scopePath.concat(@templaterState.loopOpen.tag)
					subfile= new @currentClass innerTagsContent,options
					subfile.applyTags()
					@imageId=subfile.imageId
					newContent+=subfile.content
					if ((subfile.getFullText().indexOf '{')!=-1) then throw "they shouln't be a { in replaced file: #{subfile.getFullText()} (1)"
			if subScope == true
				options= @toJson()
				options.Tags= @currentScope
				options.scopePath= options.scopePath.concat(@templaterState.loopOpen.tag)
				subfile= new @currentClass innerTagsContent,options
				subfile.applyTags()
				@imageId=subfile.imageId
				newContent+=subfile.content
				if ((subfile.getFullText().indexOf '{')!=-1) then throw "they shouln't be a { in replaced file: #{subfile.getFullText()} (1)"
			@content=@content.replace outerTagsContent, newContent
		else
			options= @toJson()
			options.Tags={}
			options.scopePath= options.scopePath.concat(@templaterState.loopOpen.tag)
			subfile= new @currentClass innerTagsContent, options
			subfile.applyTags()
			@imageId=subfile.imageId
			@content= @content.replace outerTagsContent, ""

		options= @toJson()
		nextFile= new @currentClass @content,options
		nextFile.applyTags()
		@imageId=nextFile.imageId
		if ((nextFile.getFullText().indexOf '{')!=-1) then throw "they shouln't be a { in replaced file: #{nextFile.getFullText()} (3)"
		@content=nextFile.content
		this
	dashLoop: (elementDashLoop,sharp=false) ->
		{content,start,end}= @findOuterTagsContent()
		resultFullScope = @calcInnerTextScope @content, start, end, elementDashLoop
		for t in [0..@templaterState.matches.length]
			@templaterState.charactersAdded[t]-=resultFullScope.startTag
		B= resultFullScope.text
		if (@content.indexOf B)==-1 then throw "couln't find B in @content"
		A = B
		copyA= A

		#for deleting the opening tag

		@templaterState.bracketEnd= {"i":@templaterState.loopOpen.end.i,"j":@templaterState.loopOpen.end.j}
		@templaterState.bracketStart= {"i":@templaterState.loopOpen.start.i,"j":@templaterState.loopOpen.start.j}
		if sharp==false then @templaterState.textInsideTag= "-"+@templaterState.loopOpen.element+" "+@templaterState.loopOpen.tag
		if sharp==true then @templaterState.textInsideTag= "#"+@templaterState.loopOpen.tag

		A= @replaceTagByValue("",A)
		if copyA==A then throw "A should have changed after deleting the opening tag"
		copyA= A

		@templaterState.textInsideTag= "/"+@templaterState.loopOpen.tag
		#for deleting the closing tag
		@templaterState.bracketEnd= {"i":@templaterState.loopClose.end.i,"j":@templaterState.loopClose.end.j}
		@templaterState.bracketStart= {"i":@templaterState.loopClose.start.i,"j":@templaterState.loopClose.start.j}
		A= @replaceTagByValue("",A)

		if copyA==A then throw "A should have changed after deleting the opening tag"

		return @forLoop(A,B)

	replaceXmlTag: (content,tagNumber,insideValue,spacePreserve=false,noStartTag=false) ->
		@templaterState.matches[tagNumber][2]=insideValue #so that the templaterState.matches are still correct
		startTag= @templaterState.matches[tagNumber].offset+@templaterState.charactersAdded[tagNumber]  #where the open tag starts: <w:t>
		#calculate the replacer according to the params
		if noStartTag == true
			replacer= insideValue
		else
			if spacePreserve==true
				replacer= """<#{@tagX} xml:space="preserve">#{insideValue}</#{@tagX}>"""
			else replacer= @templaterState.matches[tagNumber][1]+insideValue+"</#{@tagX}>"
		@templaterState.charactersAdded[tagNumber+1]+=replacer.length-@templaterState.matches[tagNumber][0].length
		if content.indexOf(@templaterState.matches[tagNumber][0])==-1 then throw "content #{@templaterState.matches[tagNumber][0]} not found in content"
		copyContent= content
		content = DocUtils.replaceFirstFrom content,@templaterState.matches[tagNumber][0], replacer, startTag
		@templaterState.matches[tagNumber][0]=replacer

		if copyContent==content then throw "offset problem0: didnt changed the value (should have changed from #{@templaterState.matches[@templaterState.bracketStart.i][0]} to #{replacer}"
		content

	replaceTagByValue: (newValue,content=@content) ->
		if (@templaterState.matches[@templaterState.bracketEnd.i][2].indexOf ('}'))==-1 then throw "no closing bracket at @templaterState.bracketEnd.i #{@templaterState.matches[@templaterState.bracketEnd.i][2]}"
		if (@templaterState.matches[@templaterState.bracketStart.i][2].indexOf ('{'))==-1 then throw "no opening bracket at @templaterState.bracketStart.i #{@templaterState.matches[@templaterState.bracketStart.i][2]}"
		copyContent=content
		if @templaterState.bracketEnd.i==@templaterState.bracketStart.i #<w>{aaaaa}</w>
			if (@templaterState.matches[@templaterState.bracketStart.i].first?)
				insideValue= @templaterState.matches[@templaterState.bracketStart.i][2].replace "{#{@templaterState.textInsideTag}}", newValue
				content= @replaceXmlTag(content,@templaterState.bracketStart.i,insideValue,true,true)

			else if (@templaterState.matches[@templaterState.bracketStart.i].last?)
				insideValue= @templaterState.matches[@templaterState.bracketStart.i][0].replace "{#{@templaterState.textInsideTag}}", newValue
				content= @replaceXmlTag(content,@templaterState.bracketStart.i,insideValue,true,true)
			else
				insideValue= @templaterState.matches[@templaterState.bracketStart.i][2].replace "{#{@templaterState.textInsideTag}}", newValue
				content= @replaceXmlTag(content,@templaterState.bracketStart.i,insideValue,true)

		else if @templaterState.bracketEnd.i>@templaterState.bracketStart.i

			# 1. for the first (@templaterState.bracketStart.i): replace __{.. by __value
			regexRight= /^([^{]*){.*$/
			subMatches= @templaterState.matches[@templaterState.bracketStart.i][2].match regexRight

			if @templaterState.matches[@templaterState.bracketStart.i].first? #if the content starts with:  {tag</w:t>
				content= @replaceXmlTag(content,@templaterState.bracketStart.i,newValue,true,true)
			else if @templaterState.matches[@templaterState.bracketStart.i].last?
				content= @replaceXmlTag(content,@templaterState.bracketStart.i,newValue,true,true)
			else
				insideValue=subMatches[1]+newValue
				content= @replaceXmlTag(content,@templaterState.bracketStart.i,insideValue,true)

			#2. for in between (@templaterState.bracketStart.i+1...@templaterState.bracketEnd.i) replace whole by ""
			for k in [(@templaterState.bracketStart.i+1)...@templaterState.bracketEnd.i]
				@templaterState.charactersAdded[k+1]=@templaterState.charactersAdded[k]
				content= @replaceXmlTag(content,k,"")

			#3. for the last (@templaterState.bracketEnd.i) replace ..}__ by ".." ###
			regexLeft= /^[^}]*}(.*)$/;
			insideValue = @templaterState.matches[@templaterState.bracketEnd.i][2].replace regexLeft, '$1'
			@templaterState.charactersAdded[@templaterState.bracketEnd.i+1]=@templaterState.charactersAdded[@templaterState.bracketEnd.i]
			content= @replaceXmlTag(content,k, insideValue,true)

		for match, j in @templaterState.matches when j>@templaterState.bracketEnd.i
			@templaterState.charactersAdded[j+1]=@templaterState.charactersAdded[j]
		if copyContent==content then throw "copycontent=content !!"
		content
	###
	content is the whole content to be tagged
	scope is the current scope
	returns the new content of the tagged content###
	applyTags:()->
		@templaterState.initialize()
		for match,i in @templaterState.matches
			innerText= if match[2]? then match[2] else "" #text inside the <w:t>
			for t in [i...@templaterState.matches.length]
				@templaterState.charactersAdded[t+1]=@templaterState.charactersAdded[t]
			for character,j in innerText
				@templaterState.currentStep={'i':i,'j':j}
				for m,t in @templaterState.matches when t<=i
					if @content[m.offset+@templaterState.charactersAdded[t]]!=m[0][0] then throw "no < at the beginning of #{m[0][0]} (2)"
				if character=='{'
					@templaterState.startTag()
				else if character == '}'
					@templaterState.endTag()
					result=@executeEndTag()
					if result!=undefined
						return result
				else #if character != '{' and character != '}'
					if @templaterState.inTag is true then @templaterState.textInsideTag+=character
		new ImgReplacer(this).findImages().replaceImages()
		this
	handleRecursiveCase:()->
		###
		Because xmlTemplater is recursive (meaning it can call it self), we need to handle special cases where the XML is not valid:
		For example with this string "I am</w:t></w:r></w:p><w:p><w:r><w:t>sleeping",
			- we need to match also the string that is inside an implicit <w:t> (that's the role of replacerUnshift)
			- we need to match the string that is at the right of a <w:t> (that's the role of replacerPush)
		the test: describe "scope calculation" it "should compute the scope between 2 <w:t>" makes sure that this part of code works
		It should even work if they is no XML at all, for example if the code is just "I am sleeping", in this case however, they should only be one match
		###
		replacerUnshift = (match,pn ..., offset, string)=>
			pn.unshift match #add match so that pn[0] = whole match, pn[1]= first parenthesis,...
			pn.offset= offset
			pn.first= true
			@templaterState.matches.unshift pn #add at the beginning
			@templaterState.charactersAdded.unshift 0
		@content.replace /^()([^<]+)/,replacerUnshift

		replacerPush = (match,pn ..., offset, string)=>
			pn.unshift match #add match so that pn[0] = whole match, pn[1]= first parenthesis,...
			pn.offset= offset
			pn.last= true
			@templaterState.matches.push pn #add at the beginning
			@templaterState.charactersAdded.push 0

		regex= "(<#{@tagX}[^>]*>)([^>]+)$"
		@content.replace (new RegExp(regex)),replacerPush

	#set the tag as used, so that DocxGen can return the list off all tags
	useTag: (tag) ->
		u = @usedTags
		for s,i in @scopePath
			u[s]={} unless u[s]?
			u = u[s]
		if tag!=""
			u[tag]= true
	calcIntellegentlyDashElement:()->return false
	executeEndTag:()->
		if @templaterState.loopType()=='simple'
			@content = @replaceTagByValue(@getValueFromScope(@templaterState.textInsideTag,@currentScope))
		if @templaterState.textInsideTag[0]=='/' and ('/'+@templaterState.loopOpen.tag == @templaterState.textInsideTag)
			#You DashLoop= take the outer scope only if you are in a table
			if @templaterState.loopType()=='dash'
				return @dashLoop(@templaterState.loopOpen.element)
			if @intelligentTagging==on
				dashElement=@calcIntellegentlyDashElement()
				if dashElement!=false then return @dashLoop(dashElement,true)
			return @forLoop()
		return undefined

root.XmlTemplater=XmlTemplater
