# Settings overlay for the armory_dashboard Delve app.
#
# This is NOT a fork of delve/settings.py - it imports delve's settings
# wholesale and layers armory-specific configuration on top. The container
# sets DJANGO_SETTINGS_MODULE=armory_dashboard.settings (manage.py only
# os.environ.setdefault()s 'delve.settings', so this takes precedence),
# which means delve's own source tree is never modified.
from delve.settings import *  # noqa: F401,F403

INSTALLED_APPS = INSTALLED_APPS + [
    'armory_dashboard',
]

ROOT_URLCONF = 'armory_dashboard.urls'

# Merged (not replaced) so delve's own "Delve" nav section is preserved.
DELVE_NAV_MENU = {
    **DELVE_NAV_MENU,
    'Armory Security': {
        'Overview': 'armory_overview',
        'Kubernetes Audit': 'armory_kubernetes',
        'OpenBao Audit': 'armory_openbao',
        'Failed Logins': 'armory_failed_logins',
    },
}

# Extend these here as needed, following the same merge pattern:
# DELVE_SEARCH_COMMANDS = {**DELVE_SEARCH_COMMANDS, 'my_command': 'armory_dashboard.search_commands.my_command'}
# DELVE_EXTRACTION_MAP = {**DELVE_EXTRACTION_MAP, 'my_sourcetype': json.loads}
# DELVE_PROCESSOR_MAP = {**DELVE_PROCESSOR_MAP, 'my_sourcetype': 'armory_dashboard.processors.my_processor'}
