Back-end health status page:
https://api.${SC_BASE_DOMAIN}/health

Main web application:
https://app.${SC_BASE_DOMAIN}/support

Django admin site
https://api.${SC_BASE_DOMAIN}/admin (Use the Single sign-on button)

The auto-generated random credentials are:

Username: ${ADMIN_EMAIL}
Password: ${FIRST_USER_TEMP_PASS}

You will be asked to set a new password after logging in for the first time.


An admin user has also been generated for accessing the Keycloak master realm:

https://accounts.${SC_BASE_DOMAIN}/admin/

Username: admin
Password: ${KEYCLOAK_ADMIN_PASS}
