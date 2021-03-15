# Fetch complete users list from Slack API
getusers() {
	curl https://slack.com/api/users.list \
		--silent \
		--get \
		--data 'pretty=1' \
		--header "Authorization: Bearer $BOT_TOKEN"
}

# Remove bot and guest users
extractemployees() {
	jq '
		.members |
		map(select(
			(
				.is_bot or .is_restricted |
				not
			)
			and .name != "slackbot"
		))
	'
}

# Fetch all users and extract employees
getemployees() {
	getusers | extractemployees > employees.json
}

# Retrieve first or last message for user from Slack API
findmsg() {
	local userid=$1
	local dir=$2
	curl https://slack.com/api/search.messages \
		--silent \
		--get \
		--data 'pretty=1' \
		--data-urlencode "query=from:<@$userid>" \
		--data 'count=1' \
		--data 'sort=timestamp' \
		--data "sort_dir=$dir" \
		--header "Authorization: Bearer $USER_TOKEN"
}

# Find first message from user
findfirst() {
	local userid=$1
	findmsg "$userid" 'asc'
}

# Find last message from user
findlast() {
	local userid=$1
	findmsg "$userid" 'desc'
}

# Extract timestamp from message search result; return non-zero exit status if
# user has no messages at all
msg2timestamp() {
	jq --raw-output '
		if .messages.total == 0 then
			"" | halt_error(1)
		else
			.messages.matches[0].ts |
			if test("[.]") then
				split(".")[0]
			else
				.
			end
		end
	'
}

# Convert user JSON to TSV input required for first/last lookup
extractids() {
	jq --raw-output '
		map([.id, .profile.real_name, .deleted, .profile.title]) |
		.[] |
		@tsv
	'
}

# Print blank-separated timestamps, where the first timestamp is for the first
# ever message of the provided user, and the second one for the last ever
# message. If tenures.tsv has no timestamps for a user, or if the user doesn't
# exist, nothing is printed.
gettenure() {
	local id=$1
	awk --field-separator '\t' --assign id="$id" '
		$1 == id {
			if ($5) {
				printf $5
				if ($6) {
					printf " " $6
				}
				print ""
			}
	}' tenures.tsv
}

# For each user, determine if new information might be available and fetch it
# to update the record.
tenureupdate() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' 'id' 'name' 'title' 'status' 'first' 'last'

	local id name deleted title
	while IFS=$'\t' read -r id name deleted title; do
		local first last
		read -r first last <<< "$(gettenure "$id")"

		local status
		if [[ -n $last ]]; then
			# Has two timestamps
			if [[ $deleted == 'false' ]]; then
				echo "User $id ($name) is in an invalid state" >&2
				unset id name deleted title first last status
				continue
			fi
			status='alum'
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$title" "$status" "$first" "$last"
			unset id name deleted title first last status
			continue
		fi

		if [[ -n $first ]]; then
			# Has one timestamp
			if [[ $deleted == 'false' ]]; then
				status='active'
				printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$title" "$status" "$first" "$last"
				unset id name deleted title first last status
				continue
			fi

			# Newly alum, get last
			status='alum'
			last=$(findlast "$id" | msg2timestamp)
			sleep 3
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$title" "$status" "$first" "$last"
			unset id name deleted title first last status
			continue
		fi

		# Has no timestamps
		if [[ $deleted == 'false' ]]; then
			# Fresh user
			status='fresh'
			first=$(findfirst "$id" | msg2timestamp)
			sleep 3
			if [[ -n $first ]]; then
				status='active'
			fi
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$title" "$status" "$first" "$last"
			unset id name deleted title first last status
			continue
		fi

		# Might never have said anything, or joined and left since last check
		status='noshow'
		if first=$(findfirst "$id" | msg2timestamp); then
			sleep 3
			last=$(findlast "$id" | msg2timestamp)
			sleep 3
			status='alum'
		fi

		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$title" "$status" "$first" "$last"
		unset id name deleted title first last status
	done < <(extractids < employees.json)
} > tenures_new.tsv

# Filter for tenures.tsv to remove headers, drop status field, sort by join
# date, convert Unix timestamp to YYYY-MM-DD, and add employee number
prettyprint() {
	sed '1d' \
		| cut --fields=4 --complement \
		| sort --numeric-sort --key=4,4 --field-separator=$'\t' \
		| awk --field-separator='\t' --assign OFS='\t' '
			$4 {
				$4 = strftime("%F", $4)
				if ($5)
					$5 = strftime("%F", $5)
				print
			}
		' \
		| nl
}

# Filter for prettyprint output to terminal
tocolumn() {
	column --table --separator=$'\t' --table-truncate=4
}

# Filter for prettyprint output to Markdown
tomarkdown() {
	printf '%s\n\n' '# Tenures at company'
	printf '%s | %s | %s | %s | %s | %s\n' '\#' "User ID" "Name" "Title" "Joined" "Left" \
		'-:' '-' '-' '-' '-' '-'

	sed -E '
		s/^ +//
		s/\|/\\|/g
		s/\t/ | /g
		s/ +$//
	'
}
