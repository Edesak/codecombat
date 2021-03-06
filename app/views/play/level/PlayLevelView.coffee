RootView = require 'views/core/RootView'
template = require 'templates/play/play-level-view'
{me} = require 'core/auth'
ThangType = require 'models/ThangType'
utils = require 'core/utils'
storage = require 'core/storage'
{createAetherOptions} = require 'lib/aether_utils'

# tools
Surface = require 'lib/surface/Surface'
God = require 'lib/God'
GoalManager = require 'lib/world/GoalManager'
ScriptManager = require 'lib/scripts/ScriptManager'
LevelBus = require 'lib/LevelBus'
LevelLoader = require 'lib/LevelLoader'
LevelSession = require 'models/LevelSession'
Level = require 'models/Level'
LevelComponent = require 'models/LevelComponent'
Article = require 'models/Article'
Camera = require 'lib/surface/Camera'
AudioPlayer = require 'lib/AudioPlayer'
Simulator = require 'lib/simulator/Simulator'
GameUIState = require 'models/GameUIState'

# subviews
LevelLoadingView = require './LevelLoadingView'
ProblemAlertView = require './tome/ProblemAlertView'
TomeView = require './tome/TomeView'
ChatView = require './LevelChatView'
HUDView = require './LevelHUDView'
LevelDialogueView = require './LevelDialogueView'
ControlBarView = require './ControlBarView'
LevelPlaybackView = require './LevelPlaybackView'
GoalsView = require './LevelGoalsView'
LevelFlagsView = require './LevelFlagsView'
GoldView = require './LevelGoldView'
DuelStatsView = require './DuelStatsView'
VictoryModal = require './modal/VictoryModal'
HeroVictoryModal = require './modal/HeroVictoryModal'
CourseVictoryModal = require './modal/CourseVictoryModal'
PicoCTFVictoryModal = require './modal/PicoCTFVictoryModal'
InfiniteLoopModal = require './modal/InfiniteLoopModal'
LevelSetupManager = require 'lib/LevelSetupManager'
ContactModal = require 'views/core/ContactModal'
HintsView = require './HintsView'
HintsState = require './HintsState'
WebSurfaceView = require './WebSurfaceView'

PROFILE_ME = false

module.exports = class PlayLevelView extends RootView
  id: 'level-view'
  template: template
  cache: false
  shortcutsEnabled: true
  isEditorPreview: false

  subscriptions:
    'level:set-volume': 'onSetVolume'
    'level:show-victory': 'onShowVictory'
    'level:restart': 'onRestartLevel'
    'level:highlight-dom': 'onHighlightDOM'
    'level:end-highlight-dom': 'onEndHighlight'
    'level:focus-dom': 'onFocusDom'
    'level:disable-controls': 'onDisableControls'
    'level:enable-controls': 'onEnableControls'
    'god:world-load-progress-changed': 'onWorldLoadProgressChanged'
    'god:new-world-created': 'onNewWorld'
    'god:streaming-world-updated': 'onNewWorld'
    'god:infinite-loop': 'onInfiniteLoop'
    'level:reload-from-data': 'onLevelReloadFromData'
    'level:reload-thang-type': 'onLevelReloadThangType'
    'level:started': 'onLevelStarted'
    'level:loading-view-unveiling': 'onLoadingViewUnveiling'
    'level:loading-view-unveiled': 'onLoadingViewUnveiled'
    'level:loaded': 'onLevelLoaded'
    'level:session-loaded': 'onSessionLoaded'
    'playback:real-time-playback-started': 'onRealTimePlaybackStarted'
    'playback:real-time-playback-ended': 'onRealTimePlaybackEnded'
    'ipad:memory-warning': 'onIPadMemoryWarning'
    'store:item-purchased': 'onItemPurchased'

  events:
    'click #level-done-button': 'onDonePressed'
    'click #stop-real-time-playback-button': -> Backbone.Mediator.publish 'playback:stop-real-time-playback', {}
    'click #fullscreen-editor-background-screen': (e) -> Backbone.Mediator.publish 'tome:toggle-maximize', {}
    'click .contact-link': 'onContactClicked'

  shortcuts:
    'ctrl+s': 'onCtrlS'
    'esc': 'onEscapePressed'

  # Initial Setup #############################################################

  constructor: (options, @levelID) ->
    console.profile?() if PROFILE_ME
    super options

    @courseID = options.courseID or @getQueryVariable 'course'
    @courseInstanceID = options.courseInstanceID or @getQueryVariable 'course-instance'

    @isEditorPreview = @getQueryVariable 'dev'
    @sessionID = @getQueryVariable 'session'
    @observing = @getQueryVariable 'observing'

    @opponentSessionID = @getQueryVariable('opponent')
    @opponentSessionID ?= @options.opponent
    @gameUIState = new GameUIState()

    $(window).on 'resize', @onWindowResize

    application.tracker?.enableInspectletJS(@levelID)

    if @isEditorPreview
      @supermodel.shouldSaveBackups = (model) ->  # Make sure to load possibly changed things from localStorage.
        model.constructor.className in ['Level', 'LevelComponent', 'LevelSystem', 'ThangType']
      f = => @load() unless @levelLoader  # Wait to see if it's just given to us through setLevel.
      setTimeout f, 100
    else
      @load()
      application.tracker?.trackEvent 'Started Level Load', category: 'Play Level', level: @levelID, label: @levelID unless @observing

  setLevel: (@level, givenSupermodel) ->
    @supermodel.models = givenSupermodel.models
    @supermodel.collections = givenSupermodel.collections
    @supermodel.shouldSaveBackups = givenSupermodel.shouldSaveBackups

    serializedLevel = @level.serialize {@supermodel, @session, @otherSession, headless: false, sessionless: false}
    @god?.setLevel serializedLevel
    if @world
      @world.loadFromLevel serializedLevel, false
    else
      @load()

  load: ->
    @loadStartTime = new Date()
    levelLoaderOptions = supermodel: @supermodel, levelID: @levelID, sessionID: @sessionID, opponentSessionID: @opponentSessionID, team: @getQueryVariable('team'), observing: @observing, courseID: @courseID
    if me.isSessionless()
      levelLoaderOptions.fakeSessionConfig = {}
    @levelLoader = new LevelLoader levelLoaderOptions
    @listenToOnce @levelLoader, 'world-necessities-loaded', @onWorldNecessitiesLoaded
    @listenTo @levelLoader, 'world-necessity-load-failed', @onWorldNecessityLoadFailed

  onLevelLoaded: (e) ->
    @god = new God({@gameUIState}) unless e.level.isType('web-dev')
    @setupGod() if @waitingToSetUpGod

  trackLevelLoadEnd: ->
    return if @isEditorPreview
    @loadEndTime = new Date()
    @loadDuration = @loadEndTime - @loadStartTime
    console.debug "Level unveiled after #{(@loadDuration / 1000).toFixed(2)}s"
    unless @observing
      application.tracker?.trackEvent 'Finished Level Load', category: 'Play Level', label: @levelID, level: @levelID, loadDuration: @loadDuration
      application.tracker?.trackTiming @loadDuration, 'Level Load Time', @levelID, @levelID

  isCourseMode: -> @courseID and @courseInstanceID

  showAds: ->
    return false # No ads for now.
    if application.isProduction() && !me.isPremium() && !me.isTeacher() && !window.serverConfig.picoCTF && !@isCourseMode()
      return me.getCampaignAdsGroup() is 'leaderboard-ads'
    false

  # CocoView overridden methods ###############################################

  getRenderData: ->
    c = super()
    c.world = @world
    c

  afterRender: ->
    super()
    window.onPlayLevelViewLoaded? @  # still a hack
    @insertSubView @loadingView = new LevelLoadingView autoUnveil: @options.autoUnveil or @observing, level: @levelLoader?.level ? @level, session: @levelLoader?.session ? @session  # May not have @level loaded yet
    @$el.find('#level-done-button').hide()
    $('body').addClass('is-playing')
    $('body').bind('touchmove', false) if @isIPadApp()

  afterInsert: ->
    super()

  # Partially Loaded Setup ####################################################

  onWorldNecessitiesLoaded: ->
    # Called when we have enough to build the world, but not everything is loaded
    @grabLevelLoaderData()
    team = @getQueryVariable('team') ?  @session.get('team') ? @world?.teamForPlayer(0) ? 'humans'
    @loadOpponentTeam(team)
    @setupGod()
    @setTeam team
    @initGoalManager()
    @insertSubviews()
    @initVolume()
    @register()
    @controlBar.setBus(@bus)
    @initScriptManager()

  onWorldNecessityLoadFailed: (resource) ->
    @loadingView.onLoadError(resource)

  grabLevelLoaderData: ->
    @session = @levelLoader.session
    @level = @levelLoader.level
    if @level.isType('web-dev')
      @$el.addClass 'web-dev'  # Hide some of the elements we won't be using
      return
    @world = @levelLoader.world
    @$el.addClass 'hero' if @level.isType('hero', 'hero-ladder', 'hero-coop', 'course', 'course-ladder', 'game-dev')  # TODO: figure out what this does and comment it
    @$el.addClass 'flags' if _.any(@world.thangs, (t) -> (t.programmableProperties and 'findFlags' in t.programmableProperties) or t.inventory?.flag) or @level.get('slug') is 'sky-span'
    # TODO: Update terminology to always be opponentSession or otherSession
    # TODO: E.g. if it's always opponent right now, then variable names should be opponentSession until we have coop play
    @otherSession = @levelLoader.opponentSession
    @worldLoadFakeResources = []  # first element (0) is 1%, last (99) is 100%
    for percent in [1 .. 100]
      @worldLoadFakeResources.push @supermodel.addSomethingResource 1

  onWorldLoadProgressChanged: (e) ->
    return unless e.god is @god
    return unless @worldLoadFakeResources
    @lastWorldLoadPercent ?= 0
    worldLoadPercent = Math.floor 100 * e.progress
    for percent in [@lastWorldLoadPercent + 1 .. worldLoadPercent] by 1
      @worldLoadFakeResources[percent - 1].markLoaded()
    @lastWorldLoadPercent = worldLoadPercent
    @worldFakeLoadResources = null if worldLoadPercent is 100  # Done, don't need to watch progress any more.

  loadOpponentTeam: (myTeam) ->
    opponentSpells = []
    for spellTeam, spells of @session.get('teamSpells') ? @otherSession?.get('teamSpells') ? {}
      continue if spellTeam is myTeam or not myTeam
      opponentSpells = opponentSpells.concat spells
    if (not @session.get('teamSpells')) and @otherSession?.get('teamSpells')
      @session.set('teamSpells', @otherSession.get('teamSpells'))
    opponentCode = @otherSession?.get('code') or {}
    myCode = @session.get('code') or {}
    for spell in opponentSpells
      [thang, spell] = spell.split '/'
      c = opponentCode[thang]?[spell]
      myCode[thang] ?= {}
      if c then myCode[thang][spell] = c else delete myCode[thang][spell]
    @session.set('code', myCode)

  setupGod: ->
    return if @level.isType('web-dev')
    return @waitingToSetUpGod = true unless @god
    @waitingToSetUpGod = undefined
    @god.setLevel @level.serialize {@supermodel, @session, @otherSession, headless: false, sessionless: false}
    @god.setLevelSessionIDs if @otherSession then [@session.id, @otherSession.id] else [@session.id]
    @god.setWorldClassMap @world.classMap

  setTeam: (team) ->
    team = team?.team unless _.isString team
    team ?= 'humans'
    me.team = team
    @session.set 'team', team
    Backbone.Mediator.publish 'level:team-set', team: team  # Needed for scripts
    @team = team

  initGoalManager: ->
    @goalManager = new GoalManager(@world, @level.get('goals'), @team)
    @god?.setGoalManager @goalManager

  insertSubviews: ->
    @hintsState = new HintsState({ hidden: true }, { @session, @level })
    @insertSubView @tome = new TomeView { @levelID, @session, @otherSession, thangs: @world?.thangs ? [], @supermodel, @level, @observing, @courseID, @courseInstanceID, @god, @hintsState }
    @insertSubView new LevelPlaybackView session: @session, level: @level unless @level.isType('web-dev')
    @insertSubView new GoalsView {level: @level}
    @insertSubView new LevelFlagsView levelID: @levelID, world: @world if @$el.hasClass 'flags'
    @insertSubView new GoldView {} unless @level.get('slug') in ['wakka-maul'] unless @level.isType('web-dev')
    @insertSubView new HUDView {level: @level} unless @level.isType('web-dev')
    @insertSubView new LevelDialogueView {level: @level, sessionID: @session.id}
    @insertSubView new ChatView levelID: @levelID, sessionID: @session.id, session: @session
    @insertSubView new ProblemAlertView session: @session, level: @level, supermodel: @supermodel
    @insertSubView new DuelStatsView level: @level, session: @session, otherSession: @otherSession, supermodel: @supermodel, thangs: @world.thangs if @level.isType('hero-ladder', 'course-ladder')
    @insertSubView @controlBar = new ControlBarView {worldName: utils.i18n(@level.attributes, 'name'), session: @session, level: @level, supermodel: @supermodel, courseID: @courseID, courseInstanceID: @courseInstanceID}
    @insertSubView @hintsView = new HintsView({ @session, @level, @hintsState }), @$('.hints-view')
    @insertSubView @webSurface = new WebSurfaceView {level: @level, @goalManager} if @level.isType('web-dev')
    #_.delay (=> Backbone.Mediator.publish('level:set-debug', debug: true)), 5000 if @isIPadApp()   # if me.displayName() is 'Nick'

  initVolume: ->
    volume = me.get('volume')
    volume = 1.0 unless volume?
    Backbone.Mediator.publish 'level:set-volume', volume: volume

  initScriptManager: ->
    return if @level.isType('web-dev')
    @scriptManager = new ScriptManager({scripts: @world.scripts or [], view: @, session: @session, levelID: @level.get('slug')})
    @scriptManager.loadFromSession()

  register: ->
    @bus = LevelBus.get(@levelID, @session.id)
    @bus.setSession(@session)
    @bus.setSpells @tome.spells
    #@bus.connect() if @session.get('multiplayer')  # TODO: session's multiplayer flag removed; connect bus another way if we care about it

  # Load Completed Setup ######################################################

  onSessionLoaded: (e) ->
    return if @session
    Backbone.Mediator.publish "ipad:language-chosen", language: e.session.get('codeLanguage') ? "python"
    # Just the level and session have been loaded by the level loader
    if e.level.get('slug') is 'zero-sum'
      sorcerer = '52fd1524c7e6cf99160e7bc9'
      if e.session.get('creator') is '532dbc73a622924444b68ed9'  # Wizard Dude gets his own avatar
        sorcerer = '53e126a4e06b897606d38bef'
      e.session.set 'heroConfig', {"thangType":sorcerer,"inventory":{"misc-0":"53e2396a53457600003e3f0f","programming-book":"546e266e9df4a17d0d449be5","minion":"54eb5dbc49fa2d5c905ddf56","feet":"53e214f153457600003e3eab","right-hand":"54eab7f52b7506e891ca7202","left-hand":"5463758f3839c6e02811d30f","wrists":"54693797a2b1f53ce79443e9","gloves":"5469425ca2b1f53ce7944421","torso":"546d4a549df4a17d0d449a97","neck":"54693274a2b1f53ce79443c9","eyes":"546941fda2b1f53ce794441d","head":"546d4ca19df4a17d0d449abf"}}
    else if e.level.get('slug') in ['ace-of-coders', 'elemental-wars']
      goliath = '55e1a6e876cb0948c96af9f8'
      e.session.set 'heroConfig', {"thangType":goliath,"inventory":{"eyes":"53eb99f41a100989a40ce46e","neck":"54693274a2b1f53ce79443c9","wrists":"54693797a2b1f53ce79443e9","feet":"546d4d8e9df4a17d0d449acd","minion":"54eb5bf649fa2d5c905ddf4a","programming-book":"557871261ff17fef5abee3ee"}}
    else if e.level.get('slug') is 'assembly-speed'
      raider = '55527eb0b8abf4ba1fe9a107'
      e.session.set 'heroConfig', {"thangType":raider,"inventory":{}}
    else if e.level.isType('hero', 'hero-ladder', 'hero-coop') and not _.size e.session.get('heroConfig')?.inventory ? {}
      @setupManager?.destroy()
      @setupManager = new LevelSetupManager({supermodel: @supermodel, level: e.level, levelID: @levelID, parent: @, session: e.session, courseID: @courseID, courseInstanceID: @courseInstanceID})
      @setupManager.open()

  onLoaded: ->
    _.defer => @onLevelLoaderLoaded()

  onLevelLoaderLoaded: ->
    # Everything is now loaded
    return unless @levelLoader.progress() is 1  # double check, since closing the guide may trigger this early

    # Save latest level played.
    if not @observing and not (@levelLoader.level.isType('ladder', 'ladder-tutorial'))
      me.set('lastLevel', @levelID)
      me.save()
      application.tracker?.identify()
    @saveRecentMatch() if @otherSession
    @levelLoader.destroy()
    @levelLoader = null
    if @level.isType('web-dev')
      Backbone.Mediator.publish 'level:started', {}
    else
      @initSurface()

  saveRecentMatch: ->
    allRecentlyPlayedMatches = storage.load('recently-played-matches') ? {}
    recentlyPlayedMatches = allRecentlyPlayedMatches[@levelID] ? []
    allRecentlyPlayedMatches[@levelID] = recentlyPlayedMatches
    recentlyPlayedMatches.unshift yourTeam: me.team, otherSessionID: @otherSession.id, opponentName: @otherSession.get('creatorName') unless _.find recentlyPlayedMatches, otherSessionID: @otherSession.id
    recentlyPlayedMatches.splice(8)
    storage.save 'recently-played-matches', allRecentlyPlayedMatches

  initSurface: ->
    webGLSurface = $('canvas#webgl-surface', @$el)
    normalSurface = $('canvas#normal-surface', @$el)
    surfaceOptions = {
      thangTypes: @supermodel.getModels(ThangType)
      @observing
      playerNames: @findPlayerNames()
      levelType: @level.get('type', true)
      stayVisible: @showAds()
      @gameUIState
    }
    @surface = new Surface(@world, normalSurface, webGLSurface, surfaceOptions)
    worldBounds = @world.getBounds()
    bounds = [{x: worldBounds.left, y: worldBounds.top}, {x: worldBounds.right, y: worldBounds.bottom}]
    @surface.camera.setBounds(bounds)
    @surface.camera.zoomTo({x: 0, y: 0}, 0.1, 0)

  findPlayerNames: ->
    return {} unless @level.isType('ladder', 'hero-ladder', 'course-ladder')
    playerNames = {}
    for session in [@session, @otherSession] when session?.get('team')
      playerNames[session.get('team')] = session.get('creatorName') or 'Anonymous'
    playerNames

  # Once Surface is Loaded ####################################################

  onLevelStarted: ->
    return unless @surface? or @webSurface?
    @loadingView.showReady()
    @trackLevelLoadEnd()
    if window.currentModal and not window.currentModal.destroyed and window.currentModal.constructor isnt VictoryModal
      return Backbone.Mediator.subscribeOnce 'modal:closed', @onLevelStarted, @
    @surface?.showLevel()
    Backbone.Mediator.publish 'level:set-time', time: 0
    if (@isEditorPreview or @observing) and not @getQueryVariable('intro')
      @loadingView.startUnveiling()
      @loadingView.unveil true
    else
      @scriptManager?.initializeCamera()

  onLoadingViewUnveiling: (e) ->
    @selectHero()

  onLoadingViewUnveiled: (e) ->
    if @level.isType('course-ladder', 'hero-ladder') or @observing
      # We used to autoplay by default, but now we only do it if the level says to in the introduction script.
      Backbone.Mediator.publish 'level:set-playing', playing: true
    @loadingView.$el.remove()
    @removeSubView @loadingView
    @loadingView = null
    @playAmbientSound()
    # TODO: Is it possible to create a Mongoose ObjectId for 'ls', instead of the string returned from get()?
    application.tracker?.trackEvent 'Started Level', category:'Play Level', levelID: @levelID, ls: @session?.get('_id') unless @observing
    $(window).trigger 'resize'
    _.delay (=> @perhapsStartSimulating?()), 10 * 1000

  onSetVolume: (e) ->
    createjs.Sound.setVolume(if e.volume is 1 then 0.6 else e.volume)  # Quieter for now until individual sound FX controls work again.
    if e.volume and not @ambientSound
      @playAmbientSound()

  playAmbientSound: ->
    return if @destroyed
    return if @ambientSound
    return unless me.get 'volume'
    return unless file = {Dungeon: 'ambient-dungeon', Grass: 'ambient-grass'}[@level.get('terrain')]
    src = "/file/interface/#{file}#{AudioPlayer.ext}"
    unless AudioPlayer.getStatus(src)?.loaded
      AudioPlayer.preloadSound src
      Backbone.Mediator.subscribeOnce 'audio-player:loaded', @playAmbientSound, @
      return
    @ambientSound = createjs.Sound.play src, loop: -1, volume: 0.1
    createjs.Tween.get(@ambientSound).to({volume: 1.0}, 10000)

  selectHero: ->
    Backbone.Mediator.publish 'level:suppress-selection-sounds', suppress: true
    Backbone.Mediator.publish 'tome:select-primary-sprite', {}
    Backbone.Mediator.publish 'level:suppress-selection-sounds', suppress: false
    @surface?.focusOnHero()

  perhapsStartSimulating: ->
    return unless @shouldSimulate()
    return console.error "Should not auto-simulate until we fix how these languages are loaded"
    # TODO: how can we not require these as part of /play bundle?
    ##require "vendor/aether-#{codeLanguage}" for codeLanguage in ['javascript', 'python', 'coffeescript', 'lua', 'java']
    #require 'vendor/aether-javascript'
    #require 'vendor/aether-python'
    #require 'vendor/aether-coffeescript'
    #require 'vendor/aether-lua'
    #require 'vendor/aether-java'
    @simulateNextGame()

  simulateNextGame: ->
    return @simulator.fetchAndSimulateOneGame() if @simulator
    simulatorOptions = background: true, leagueID: @courseInstanceID
    simulatorOptions.levelID = @level.get('slug') if @level.isType('course-ladder', 'hero-ladder')
    @simulator = new Simulator simulatorOptions
    # Crude method of mitigating Simulator memory leak issues
    fetchAndSimulateOneGameOriginal = @simulator.fetchAndSimulateOneGame
    @simulator.fetchAndSimulateOneGame = =>
      if @simulator.simulatedByYou >= 10
        console.log '------------------- Destroying Simulator and making a new one -----------------'
        @simulator.destroy()
        @simulator = null
        @simulateNextGame()
      else
        fetchAndSimulateOneGameOriginal.apply @simulator
    @simulator.fetchAndSimulateOneGame()

  shouldSimulate: ->
    return true if @getQueryVariable('simulate') is true
    return false if @getQueryVariable('simulate') is false
    stillBuggy = true  # Keep this true while we still haven't fixed the zombie worker problem when simulating the more difficult levels on Chrome
    defaultCores = 2
    cores = window.navigator.hardwareConcurrency or defaultCores  # Available on Chrome/Opera, soon Safari
    defaultHeapLimit = 793000000
    heapLimit = window.performance?.memory?.jsHeapSizeLimit or defaultHeapLimit  # Only available on Chrome, basically just says 32- vs. 64-bit
    gamesSimulated = me.get('simulatedBy')
    console.debug "Should we start simulating? Cores:", window.navigator.hardwareConcurrency, "Heap limit:", window.performance?.memory?.jsHeapSizeLimit, "Load duration:", @loadDuration
    return false unless $.browser?.desktop
    return false if $.browser?.msie or $.browser?.msedge
    return false if $.browser.linux
    return false if me.level() < 8
    if @level.isType('course', 'game-dev', 'web-dev')
      return false
    else if @level.isType('hero') and gamesSimulated
      return false if stillBuggy
      return false if cores < 8
      return false if heapLimit < defaultHeapLimit
      return false if @loadDuration > 10000
    else if @level.isType('hero-ladder') and gamesSimulated
      return false if stillBuggy
      return false if cores < 4
      return false if heapLimit < defaultHeapLimit
      return false if @loadDuration > 15000
    else if @level.isType('hero-ladder') and not gamesSimulated
      return false if stillBuggy
      return false if cores < 8
      return false if heapLimit <= defaultHeapLimit
      return false if @loadDuration > 20000
    else if @level.isType('course-ladder')
      return false if cores <= defaultCores
      return false if heapLimit < defaultHeapLimit
      return false if @loadDuration > 18000
    else
      console.warn "Unwritten level type simulation heuristics; fill these in for new level type #{@level.get('type')}?"
      return false if stillBuggy
      return false if cores < 8
      return false if heapLimit < defaultHeapLimit
      return false if @loadDuration > 10000
    console.debug "We should have the power. Begin background ladder simulation."
    true

  # callbacks

  onCtrlS: (e) ->
    e.preventDefault()

  onEscapePressed: (e) ->
    return unless @$el.hasClass 'real-time'
    Backbone.Mediator.publish 'playback:stop-real-time-playback', {}

  onLevelReloadFromData: (e) ->
    isReload = Boolean @world
    @setLevel e.level, e.supermodel
    if isReload
      @scriptManager.setScripts(e.level.get('scripts'))
      Backbone.Mediator.publish 'tome:cast-spell', {}  # a bit hacky

  onLevelReloadThangType: (e) ->
    tt = e.thangType
    for url, model of @supermodel.models
      if model.id is tt.id
        for key, val of tt.attributes
          model.attributes[key] = val
        break
    Backbone.Mediator.publish 'tome:cast-spell', {}

  onWindowResize: (e) =>
    @endHighlight()

  onDisableControls: (e) ->
    return if e.controls and not ('level' in e.controls)
    @shortcutsEnabled = false
    @wasFocusedOn = document.activeElement
    $('body').focus()

  onEnableControls: (e) ->
    return if e.controls? and not ('level' in e.controls)
    @shortcutsEnabled = true
    $(@wasFocusedOn).focus() if @wasFocusedOn
    @wasFocusedOn = null

  onDonePressed: -> @showVictory()

  onShowVictory: (e) ->
    $('#level-done-button').show() unless @level.isType('hero', 'hero-ladder', 'hero-coop', 'course', 'course-ladder', 'game-dev', 'web-dev')
    @showVictory() if e.showModal
    return if @victorySeen
    @victorySeen = true
    victoryTime = (new Date()) - @loadEndTime
    if not @observing and victoryTime > 10 * 1000   # Don't track it if we're reloading an already-beaten level
      application.tracker?.trackEvent 'Saw Victory',
        category: 'Play Level'
        level: @level.get('name')
        label: @level.get('name')
        levelID: @levelID
        ls: @session?.get('_id')
      application.tracker?.trackTiming victoryTime, 'Level Victory Time', @levelID, @levelID

  showVictory: ->
    return if @level.hasLocalChanges()  # Don't award achievements when beating level changed in level editor
    @endHighlight()
    options = {level: @level, supermodel: @supermodel, session: @session, hasReceivedMemoryWarning: @hasReceivedMemoryWarning, courseID: @courseID, courseInstanceID: @courseInstanceID, world: @world}
    ModalClass = if @level.isType('hero', 'hero-ladder', 'hero-coop', 'course', 'course-ladder', 'game-dev', 'web-dev') then HeroVictoryModal else VictoryModal
    ModalClass = CourseVictoryModal if @isCourseMode() or me.isSessionless()
    if @level.isType('course-ladder')
      ModalClass = CourseVictoryModal
      options.courseInstanceID = @getQueryVariable 'league'
    ModalClass = PicoCTFVictoryModal if window.serverConfig.picoCTF
    victoryModal = new ModalClass(options)
    @openModalView(victoryModal)
    if me.get('anonymous')
      window.nextURL = '/play/' + (@level.get('campaign') ? '')  # Signup will go here on completion instead of reloading.

  onRestartLevel: ->
    @tome.reloadAllCode()
    Backbone.Mediator.publish 'level:restarted', {}
    $('#level-done-button', @$el).hide()
    application.tracker?.trackEvent 'Confirmed Restart', category: 'Play Level', level: @level.get('name'), label: @level.get('name') unless @observing

  onInfiniteLoop: (e) ->
    return unless e.firstWorld and e.god is @god
    @openModalView new InfiniteLoopModal nonUserCodeProblem: e.nonUserCodeProblem
    application.tracker?.trackEvent 'Saw Initial Infinite Loop', category: 'Play Level', level: @level.get('name'), label: @level.get('name') unless @observing

  onHighlightDOM: (e) -> @highlightElement e.selector, delay: e.delay, sides: e.sides, offset: e.offset, rotation: e.rotation

  onEndHighlight: -> @endHighlight()

  onFocusDom: (e) -> $(e.selector).focus()

  onContactClicked: (e) ->
    Backbone.Mediator.publish 'level:contact-button-pressed', {}
    @openModalView contactModal = new ContactModal levelID: @level.get('slug') or @level.id, courseID: @courseID, courseInstanceID: @courseInstanceID
    screenshot = @surface.screenshot(1, 'image/png', 1.0, 1)
    body =
      b64png: screenshot.replace 'data:image/png;base64,', ''
      filename: "screenshot-#{@levelID}-#{_.string.slugify((new Date()).toString())}.png"
      path: "db/user/#{me.id}"
      mimetype: 'image/png'
    contactModal.screenshotURL = "http://codecombat.com/file/#{body.path}/#{body.filename}"
    window.screenshot = screenshot
    window.screenshotURL = contactModal.screenshotURL
    $.ajax '/file', type: 'POST', data: body, success: (e) ->
      contactModal.updateScreenshot?()

  # Dynamic sound loading

  onNewWorld: (e) ->
    return if @headless
    scripts = @world.scripts  # Since these worlds don't have scripts, preserve them.
    @world = e.world
    @world.scripts = scripts
    thangTypes = @supermodel.getModels(ThangType)
    startFrame = @lastWorldFramesLoaded ? 0
    finishedLoading = @world.frames.length is @world.totalFrames
    if finishedLoading
      @lastWorldFramesLoaded = 0
      if @waitingForSubmissionComplete
        _.defer @onSubmissionComplete  # Give it a frame to make sure we have the latest goals
        @waitingForSubmissionComplete = false
    else
      @lastWorldFramesLoaded = @world.frames.length
    for [spriteName, message] in @world.thangDialogueSounds startFrame
      continue unless thangType = _.find thangTypes, (m) -> m.get('name') is spriteName
      continue unless sound = AudioPlayer.soundForDialogue message, thangType.get('soundTriggers')
      AudioPlayer.preloadSoundReference sound

  # Real-time playback
  onRealTimePlaybackStarted: (e) ->
    @$el.addClass('real-time').focus()
    @onWindowResize()

  onRealTimePlaybackEnded: (e) ->
    return unless @$el.hasClass 'real-time'
    @$el.removeClass 'real-time'
    @onWindowResize()
    if @world.frames.length is @world.totalFrames and not @surface.countdownScreen?.showing
      _.delay @onSubmissionComplete, 750  # Wait for transition to end.
    else
      @waitingForSubmissionComplete = true

  onSubmissionComplete: =>
    return if @destroyed
    Backbone.Mediator.publish 'level:set-time', ratio: 1
    return if @level.hasLocalChanges()  # Don't award achievements when beating level changed in level editor
    if @goalManager.checkOverallStatus() is 'success'
      showModalFn = -> Backbone.Mediator.publish 'level:show-victory', showModal: true
      @session.recordScores @world.scores, @level
      if @level.get 'replayable'
        @session.increaseDifficulty showModalFn
      else
        showModalFn()

  destroy: ->
    @levelLoader?.destroy()
    @surface?.destroy()
    @god?.destroy()
    @goalManager?.destroy()
    @scriptManager?.destroy()
    @setupManager?.destroy()
    @simulator?.destroy()
    if ambientSound = @ambientSound
      # Doesn't seem to work; stops immediately.
      createjs.Tween.get(ambientSound).to({volume: 0.0}, 1500).call -> ambientSound.stop()
    $(window).off 'resize', @onWindowResize
    delete window.world # not sure where this is set, but this is one way to clean it up
    @bus?.destroy()
    #@instance.save() unless @instance.loading
    delete window.nextURL
    console.profileEnd?() if PROFILE_ME
    application.tracker?.disableInspectletJS()
    super()

  onIPadMemoryWarning: (e) ->
    @hasReceivedMemoryWarning = true

  onItemPurchased: (e) ->
    heroConfig = @session.get('heroConfig') ? {}
    inventory = heroConfig.inventory ? {}
    slot = e.item.getAllowedSlots()[0]
    if slot and not inventory[slot]
      # Open up the inventory modal so they can equip the new item
      @setupManager?.destroy()
      @setupManager = new LevelSetupManager({supermodel: @supermodel, level: @level, levelID: @levelID, parent: @, session: @session, hadEverChosenHero: true})
      @setupManager.open()
