--http date parsing to os.date() format (except fields yday & isdst)
local glue = require'glue'

local wdays = glue.index{'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'}
local weekdays = glue.index{'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'}
local months = glue.index{'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'}

local function check(w,d,mo,y,h,m,s)
	return w and mo and d >= 1 and d <= 31 and y <= 9999
			and h <= 23 and m <= 59 and s <= 59
end

--wkday "," SP 2DIGIT-day SP month SP 4DIGIT-year SP 2DIGIT ":" 2DIGIT ":" 2DIGIT SP "GMT"
--eg. Sun, 06 Nov 1994 08:49:37 GMT
local function rfc1123date(s)
	local w,d,mo,y,h,m,s = s:match'([A-Za-z]+), (%d+) ([A-Za-z]+) (%d+) (%d+):(%d+):(%d+) GMT'
	d,y,h,m,s = tonumber(d),tonumber(y),tonumber(h),tonumber(m),tonumber(s)
	w = wdays[w]
	mo = months[mo]
	if not check(w,d,mo,y,h,m,s) then return end
	return {wday = w, day = d, year = y, month = mo,
			hour = h, min = m, sec = s}
end

--weekday "," SP 2DIGIT "-" month "-" 2DIGIT SP 2DIGIT ":" 2DIGIT ":" 2DIGIT SP "GMT"
--eg. Sunday, 06-Nov-94 08:49:37 GMT
local function rfc850date(s)
	local w,d,mo,y,h,m,s = s:match'([A-Za-z]+), (%d+)%-([A-Za-z]+)%-(%d+) (%d+):(%d+):(%d+) GMT'
	d,y,h,m,s = tonumber(d),tonumber(y),tonumber(h),tonumber(m),tonumber(s)
	w = weekdays[w]
	mo = months[mo]
	if y then y = y + (y > 50 and 1900 or 2000) end
	if not check(w,d,mo,y,h,m,s) then return end
	return {wday = w, day = d, year = y,
			month = mo, hour = h, min = m, sec = s}
end

--wkday SP month SP ( 2DIGIT | ( SP 1DIGIT )) SP 2DIGIT ":" 2DIGIT ":" 2DIGIT SP 4DIGIT
--eg. Sun Nov  6 08:49:37 1994
local function asctimedate(s)
	local w,mo,d,h,m,s,y = s:match'([A-Za-z]+) ([A-Za-z]+) +(%d+) (%d+):(%d+):(%d+) (%d+)'
	d,y,h,m,s = tonumber(d),tonumber(y),tonumber(h),tonumber(m),tonumber(s)
	w = wdays[w]
	mo = months[mo]
	if not check(w,d,mo,y,h,m,s) then return end
	return {wday = w, day = d, year = y, month = mo,
			hour = h, min = m, sec = s}
end

local function date(s)
	return rfc1123date(s) or rfc850date(s) or asctimedate(s)
end

if not ... then
	require'unit'
	local d = {day = 6, sec = 37, wday = 1, min = 49, year = 1994, month = 11, hour = 8}
	test(date'Sun, 06 Nov 1994 08:49:37 GMT', d)
	test(date'Sunday, 06-Nov-94 08:49:37 GMT', d)
	test(date'Sun Nov  6 08:49:37 1994', d)
	test(date'Sun Nov 66 08:49:37 1994', nil)
	test(date'SundaY, 06-Nov-94 08:49:37 GMT', nil)
end

return {
	parse = date
}
