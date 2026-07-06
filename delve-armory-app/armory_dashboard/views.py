from django.shortcuts import render

# Query strings live here, not inlined in the templates. Several of these
# use quoting that Django's own template-tag argument lexer can't represent
# safely (eg. qs_order_by "'-count'" needs a literal double-quote AND a
# literal single-quote inside one token) - passing them as context variables
# sidesteps that entirely and keeps the templates readable.

OVERVIEW_QUERIES = {
    'by_index': (
        "search --last-day"
        " | qs_group_by index count=Count('id')"
        " | chart --type bar --x-field index --y-field count"
    ),
    'by_index_over_time': (
        "search --last-day"
        " | qs_annotate hour=Trunc(created,kind='hour',output_field=DateTimeField)"
        " | qs_group_by hour index count=Count('id')"
        " | chart --type bar --x-field hour --y-field count --by-field index --time-x hour"
    ),
    'openbao_denied': (
        "search --last-day index=openbao extracted_fields__auth__policy_results__allowed=False"
        " | qs_values created extracted_fields__auth__display_name"
        " extracted_fields__request__path extracted_fields__request__operation"
    ),
}

FAILED_LOGIN_QUERIES = {
    'brute_force': (
        "search --last-day index=keycloak extracted_fields__type=LOGIN_ERROR"
        " | qs_group_by extracted_fields__user_id extracted_fields__ip_address count=Count('id')"
        " | qs_having count__gte=5"
        " | qs_order_by \"'-count'\""
    ),
    'client_logins': (
        "search --last-day index=keycloak extracted_fields__type=CLIENT_LOGIN"
        " | select created extracted_fields__client_id extracted_fields__ip_address"
        " | sort -d created"
    ),
}


def overview(request):
    return render(request, 'armory_dashboard/overview.html', OVERVIEW_QUERIES)


def failed_logins(request):
    return render(request, 'armory_dashboard/failed_logins.html', FAILED_LOGIN_QUERIES)
