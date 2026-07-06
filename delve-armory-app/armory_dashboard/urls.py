# Wraps delve.urls rather than replacing it, so /explore, /api/, /admin/,
# etc. keep working untouched. Our pages are additive.
from delve.urls import urlpatterns as delve_urlpatterns
from django.urls import path

from . import views

urlpatterns = delve_urlpatterns + [
    path('armory/', views.overview, name='armory_overview'),
    path('armory/failed-logins/', views.failed_logins, name='armory_failed_logins'),
]
