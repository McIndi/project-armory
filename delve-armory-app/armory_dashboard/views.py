from django.shortcuts import render

# Query strings live here, not inlined in the templates. Several of these
# use quoting that Django's own template-tag argument lexer can't represent
# safely (eg. qs_order_by "'-count'" needs a literal double-quote AND a
# literal single-quote inside one token) - passing them as context variables
# sidesteps that entirely and keeps the templates readable.

OVERVIEW_QUERIES = {
    'by_index_table': (
        "search --last-day"
        " | qs_group_by index count=Count('id')"
        " | qs_order_by \"'-count'\""
    ),
    'by_index': (
        "search --last-day"
        " | qs_group_by index count=Count('id')"
        " | qs_order_by \"'-count'\""
        " | chart --type bar --x-field index --y-field count"
    ),
    'by_index_over_time': (
        "search --last-day"
        " | qs_annotate hour=\"Trunc(created, kind='hour', output_field=DateTimeField)\""
        " | qs_group_by hour index count=Count('id')"
        " | chart --type bar --x-field hour --y-field count --by-field index --time-x hour"
    ),
}

K8S_QUERIES = {
    'secrets_reads': (
        "search --last-day index=k8s extracted_fields__objectRef__resource=secrets extracted_fields__verb=get"
        " | qs_values created extracted_fields__user__username extracted_fields__objectRef__namespace"
        " extracted_fields__objectRef__name extracted_fields__responseStatus__code"
        " | sort -d created"
    ),
    'failed_by_identity': (
        "search --last-day index=k8s"
        " | qs_annotate status_code=\"Cast(KT('extracted_fields__responseStatus__code'), IntegerField)\""
        " | qs_filter status_code__gte=400"
        " | qs_group_by extracted_fields__user__username status_code count=Count('id')"
        " | qs_order_by \"'-count'\""
    ),
    'unusual_non_node': (
        "search --last-day index=k8s"
        " | qs_exclude extracted_fields__user__username__startswith=\"'system:node'\""
        " | qs_group_by extracted_fields__user__username extracted_fields__verb extracted_fields__objectRef__resource"
        " count=Count('id')"
        " | qs_order_by \"'-count'\""
    ),
}

OPENBAO_QUERIES = {
    'read_frequency': (
        "search --last-day index=openbao extracted_fields__request__operation=read"
        " | qs_group_by extracted_fields__auth__display_name extracted_fields__request__path count=Count('id')"
        " | qs_order_by \"'-count'\""
    ),
    'policy_denied': (
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


def kubernetes(request):
    return render(request, 'armory_dashboard/kubernetes.html', K8S_QUERIES)


def openbao(request):
    return render(request, 'armory_dashboard/openbao.html', OPENBAO_QUERIES)
