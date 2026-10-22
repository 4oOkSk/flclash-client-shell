package main

func patchConfigValue[Value any](target *Value, patch *Value, publish ...func(Value)) {
	if patch == nil {
		return
	}
	*target = *patch
	for _, apply := range publish {
		apply(*target)
	}
}
