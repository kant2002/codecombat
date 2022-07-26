ace = require('lib/aceContainer')
Range = ace.require('ace/range').Range

# This class can either wrap an AetherProblem,
# or act as a general runtime error container for web-dev iFrame errors.
# TODO: Use subclasses? Might need a factory pattern for that (bleh)
module.exports = class Problem
  annotation: null
  markerRange: null
  # Construction with AetherProblem will include all but `error`
  # Construction with a standard error will have `error`, `isCast`, `levelID`, `ace`
  constructor: ({ @aether, @aetherProblem, @ace, isCast, @levelID, error, userCodeHasChangedSinceLastCast }) ->
    isCast ?= false
    if @aetherProblem
      @annotation = @buildAnnotationFromAetherProblem(@aetherProblem)
      { @lineMarkerRange, @textMarkerRange } = @buildMarkerRangesFromAetherProblem(@aetherProblem) if isCast

      { @level, @range, @message, @hint, @userInfo, @errorCode, @i18nParams } = @aetherProblem
      { @row, @column: col } = @aetherProblem.range?[0] or {}
      @createdBy = 'aether'
    else
      unless userCodeHasChangedSinceLastCast
        @annotation = @buildAnnotationFromWebDevError(error)
        { @lineMarkerRange, @textMarkerRange } = @buildMarkerRangesFromWebDevError(error)

      @level = 'error'
      @row = error.line
      @column = error.column
      @message = error.message or 'Unknown Error'
      if error.line and not userCodeHasChangedSinceLastCast
        @message = "Line #{error.line + 1}: " + @message # Ace's gutter numbers are 1-indexed but annotation.rows are 0-indexed
      if userCodeHasChangedSinceLastCast
        @hint = "This error was generated by old code — Try running your new code first."
      else
        @hint = undefined
      @userInfo = undefined
      @createdBy = 'web-dev-iframe'
      # TODO: Include runtime/transpile error types depending on something?

    @message = @translate(@message, @errorCode, @i18nParams)
    @hint = @translate(@hint)
    # TODO: get ACE screen line, too, for positioning, since any multiline "lines" will mess up positioning
    Backbone.Mediator.publish("problem:problem-created", line: @annotation.row, text: @annotation.text) if application.isIPadApp

  isEqual: (problem) ->
    _.all ['row', 'column', 'level', 'column', 'message', 'hint'], (attr) =>
      @[attr] is problem[attr]

  destroy: ->
    @removeMarkerRanges()
    @userCodeProblem.off() if @userCodeProblem

  buildAnnotationFromWebDevError: (error) ->
    translatedErrorMessage = @translate(error.message)
    {
      row: error.line
      column: error.column
      raw: translatedErrorMessage
      text: translatedErrorMessage
      type: 'error'
      createdBy: 'web-dev-iframe'
    }

  buildAnnotationFromAetherProblem: (aetherProblem) ->
    return unless aetherProblem.range
    text = @translate(aetherProblem.message.replace /^Line \d+: /, '')
    start = aetherProblem.range[0]
    {
      row: start.row,
      column: start.col,
      raw: text,
      text: text,
      type: @aetherProblem.level ? 'error'
      createdBy: 'aether'
    }

  buildMarkerRangesFromWebDevError: (error) ->
    lineMarkerRange = new Range error.line, 0, error.line, 1
    lineMarkerRange.start = @ace.getSession().getDocument().createAnchor lineMarkerRange.start
    lineMarkerRange.end = @ace.getSession().getDocument().createAnchor lineMarkerRange.end
    lineMarkerRange.id = @ace.getSession().addMarker lineMarkerRange, 'problem-line', 'fullLine'
    textMarkerRange = undefined # We don't get any per-character info from standard errors
    { lineMarkerRange, textMarkerRange }

  buildMarkerRangesFromAetherProblem: (aetherProblem) ->
    return {} unless aetherProblem.range
    [start, end] = aetherProblem.range
    textClazz = "problem-marker-#{aetherProblem.level}"
    textMarkerRange = new Range start.row, start.col, end.row, end.col
    textMarkerRange.start = @ace.getSession().getDocument().createAnchor textMarkerRange.start
    textMarkerRange.end = @ace.getSession().getDocument().createAnchor textMarkerRange.end
    textMarkerRange.id = @ace.getSession().addMarker textMarkerRange, textClazz, 'text'
    lineClazz = "problem-line"
    lineMarkerRange = new Range start.row, start.col, end.row, end.col
    lineMarkerRange.start = @ace.getSession().getDocument().createAnchor lineMarkerRange.start
    lineMarkerRange.end = @ace.getSession().getDocument().createAnchor lineMarkerRange.end
    lineMarkerRange.id = @ace.getSession().addMarker lineMarkerRange, lineClazz, 'fullLine'
    { lineMarkerRange, textMarkerRange }

  removeMarkerRanges: ->
    if @textMarkerRange
      @ace.getSession().removeMarker @textMarkerRange.id
      @textMarkerRange.start.detach()
      @textMarkerRange.end.detach()
    if @lineMarkerRange
      @ace.getSession().removeMarker @lineMarkerRange.id
      @lineMarkerRange.start.detach()
      @lineMarkerRange.end.detach()

  # Here we take a string from the locale file, find the placeholders ($1/$2/etc)
  #   and replace them with capture groups (.+),
  # returns a regex that will match against the error message
  #   and capture any dynamic values in the text
  makeTranslationRegex: (englishString) ->
    escapeRegExp = (str) ->
      # https://stackoverflow.com/questions/3446170/escape-string-for-use-in-javascript-regex
      return str.replace(/[\-\[\]\/\{\}\(\)\*\+\?\.\\\^\$\|]/g, "\\$&")
    new RegExp(escapeRegExp(englishString).replace(/\\\$\d/g, '(.+)').replace(/ +/g, ' +'))

  translate: (msg, errorCode, i18nParams) ->
    return msg if not msg
    if /\n/.test(msg) # Translate each line independently, since regexes act weirdly with newlines
      return msg.split('\n').map((line) => @translate(line)).join('\n')

    msg = msg.replace /([A-Za-z]+Error:) \1/, '$1'
    return msg if $.i18n.language in ['en', 'en-US']

    # Separately handle line number and error type prefixes
    en = require('locale/en').translation
    applyReplacementTranslation = (text, regex, key) =>
      fullKey = "esper.#{key}"
      replacementTemplate = $.i18n.t(fullKey)
      return if replacementTemplate is fullKey
      # This carries over any capture groups from the regex into $N placeholders in the template string
      replaced = text.replace regex, replacementTemplate
      if replaced isnt text
        return [replaced.replace(/``/g, '`'), true]
      return [text, false]

    # These need to be applied in this order, before the main text is translated
    prefixKeys = ['line_no', 'uncaught', 'reference_error', 'argument_error', 'type_error', 'syntax_error', 'error']

    msgs = msg.split(': ')
    for i of msgs
      m = msgs[i]
      m += ': ' unless +i == msgs.length - 1 # i is string
      for keySet in [prefixKeys, Object.keys(_.omit(en.esper), prefixKeys)]
        for translationKey in keySet
          englishString = en.esper[translationKey]
          regex = @makeTranslationRegex(englishString)
          [m, didTranslate] = applyReplacementTranslation m, regex, translationKey
          break if didTranslate and keySet isnt prefixKeys
      msgs[i] = m

    if errorCode
      msgs[msgs.length - 1] = $.i18n.t("esper.error_#{_.string.underscored(errorCode)}", i18nParams)

    msgs.join('')
