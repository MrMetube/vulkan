package main

import "base:runtime"
import "core:fmt"

print   :: fmt.printf
sprint  :: fmt.aprintf
tprint  :: fmt.tprintf
cprint  :: fmt.caprintf
ctprint :: fmt.ctprintf

@(init)
view_init :: proc "contextless" () {
    context = runtime.default_context()
    
    if fmt._user_formatters == nil {
        user_formatters, err := new(type_of(fmt._user_formatters^))
        assert(err == nil)
        fmt.set_user_formatters(user_formatters)
    }
    
    err: fmt.Register_User_Formatter_Error
	err = fmt.register_user_formatter(View_Magnitude,  View_Magnitude_Formatter);  assert(err == .None)
	err = fmt.register_user_formatter(View_Percentage, View_Percentage_Formatter); assert(err == .None)
}

////////////////////////////////////////////////

View_Magnitude :: struct {
    value:     u64,
    precision: int,
}

view_magnitude :: proc (#any_int value: u64, #any_int precision: int = 1) -> View_Magnitude {
    result := View_Magnitude {
        value     = value,
        precision = precision,
    }
    return result
}

View_Magnitude_Formatter :: proc (info: ^fmt.Info, arg: any, verb: rune) -> bool {
    view := cast(^View_Magnitude) arg.data
    
    value: f64
    symbol: rune
    switch {
    case view.value > 1000_000_000: symbol, value = 'G', cast(f64) view.value / 1000_000_000
    case view.value > 1000_000:     symbol, value = 'M', cast(f64) view.value / 1000_000
    case view.value > 1000:         symbol, value = 'k', cast(f64) view.value / 1000
    case:                           symbol, value = ' ', cast(f64) view.value
    }
    
    info.prec = view.precision
    info.prec_set = true
    fmt.fmt_float(info, value, 8 * size_of(view.value), 'f')
    fmt.fmt_rune(info, symbol, 'v')
    
    return true
}

////////////////////////////////////////////////

View_Percentage :: struct {
    value: f64,
}

view_percentage :: proc { view_percentage_value, view_percentage_division }
view_percentage_value :: proc (value: $T) -> View_Percentage {
    result := View_Percentage { value = cast(f64) value }
    return result
}
view_percentage_division :: proc (dividend: $T, denominator: T) -> View_Percentage {
    value := safe_ratio_or_zero(cast(f64) dividend, cast(f64) denominator)
    result := View_Percentage { value = value }
    return result
}

View_Percentage_Formatter :: proc (info: ^fmt.Info, arg: any, verb: rune) -> bool {
    view := cast(^View_Percentage) arg.data
    
    info.width = 2
    info.width_set = true
    info.space = true
    info.prec = 2
    info.prec_set = true
    fmt.fmt_float(info, view.value * 100, 8 * size_of(view.value), 'f')
    fmt.fmt_rune(info, '%', 'v')
    return true
}