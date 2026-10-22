package main

type methodHandler func(*MethodCall, MethodResponse)

var coreMethodHandlers = map[CoreMethod]methodHandler{
	initClashMethod:      pointerMethod(handleInitClash),
	getIsInitMethod:      resultMethod(handleGetIsInit),
	forceGcMethod:        actionMethod(handleForceGC),
	shutdownMethod:       resultMethod(handleShutdown),
	validateConfigMethod: argumentMethod(handleValidateConfig),
	evaluateScriptMethod: decodedMethod(func(params *ScriptParams, response MethodResponse) {
		value, err := evaluateScript(params)
		if err != nil {
			response.failure("script_failed", err.Error(), nil)
			return
		}
		response.success(value)
	}),
	updateConfigMethod:           pointerMethod(handleUpdateConfig),
	getProxiesMethod:             resultMethod(handleGetProxies),
	getTrafficMethod:             argumentMethod(handleGetTraffic),
	getTotalTrafficMethod:        argumentMethod(handleGetTotalTraffic),
	resetTrafficMethod:           actionMethod(handleResetTraffic),
	getConnectionsMethod:         resultMethod(handleGetConnections),
	closeConnectionsMethod:       resultMethod(handleCloseConnections),
	resetConnectionsMethod:       resultMethod(handleResetConnections),
	closeConnectionMethod:        argumentMethod(handleCloseConnection),
	getExternalProvidersMethod:   resultMethod(handleGetExternalProviders),
	getExternalProviderMethod:    argumentMethod(handleGetExternalProvider),
	updateExternalProviderMethod: callbackMethod(handleUpdateExternalProvider),
	startLogMethod:               actionMethod(handleStartLog),
	stopLogMethod:                actionMethod(handleStopLog),
	startListenerMethod:          resultMethod(handleStartListener),
	stopListenerMethod:           resultMethod(handleStopListener),
	getCountryCodeMethod:         callbackMethod(handleGetCountryCode),
	setupConfigMethod: func(call *MethodCall, response MethodResponse) {
		params := defaultSetupParams()
		if decodeMethodArguments(call, response, params) {
			response.success(handleSetupConfig(params))
		}
	},
	changeProxyMethod: decodedMethod(func(params *ChangeProxyParams, response MethodResponse) {
		handleChangeProxy(params, func(value string) { response.success(value) })
	}),
	asyncTestDelayMethod: decodedMethod(func(params *TestDelayParams, response MethodResponse) {
		handleAsyncTestDelay(params, func(value *Delay) { response.success(value) })
	}),
	getConfigMethod: decodedMethod(func(path *string, response MethodResponse) {
		config, err := handleGetConfig(*path)
		if err != nil {
			response.failure("core_error", err.Error(), nil)
			return
		}
		response.success(config)
	}),
	updateGeoDataMethod: argumentMethod(func(geoType string) string {
		handleUpdateGeoData(geoType)
		return ""
	}),
	sideLoadExternalProviderMethod: callbackMethod(func(params map[string]string, reply func(string)) {
		handleSideLoadExternalProvider(params["providerName"], []byte(params["data"]), reply)
	}),
	getMemoryMethod: func(_ *MethodCall, response MethodResponse) {
		handleGetMemory(func(value uint64) { response.success(value) })
	},
	clearEffectMethod: decodedMethod(func(profileID *int64, response MethodResponse) {
		handleClearEffect(*profileID, response)
	}),
}

func decodedMethod[Arguments any](handler func(*Arguments, MethodResponse)) methodHandler {
	return func(call *MethodCall, response MethodResponse) {
		var arguments Arguments
		if decodeMethodArguments(call, response, &arguments) {
			handler(&arguments, response)
		}
	}
}

func pointerMethod[Arguments, Result any](handler func(*Arguments) Result) methodHandler {
	return decodedMethod(func(arguments *Arguments, response MethodResponse) {
		response.success(handler(arguments))
	})
}

func argumentMethod[Arguments, Result any](handler func(Arguments) Result) methodHandler {
	return pointerMethod(func(arguments *Arguments) Result { return handler(*arguments) })
}

func callbackMethod[Arguments, Result any](handler func(Arguments, func(Result))) methodHandler {
	return decodedMethod(func(arguments *Arguments, response MethodResponse) {
		handler(*arguments, func(result Result) { response.success(result) })
	})
}

func resultMethod[Result any](handler func() Result) methodHandler {
	return func(_ *MethodCall, response MethodResponse) { response.success(handler()) }
}

func actionMethod(handler func()) methodHandler {
	return resultMethod(func() bool {
		handler()
		return true
	})
}
