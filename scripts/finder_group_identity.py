"""macOS team-qualified App Group and Mach service build identity."""
import re
GROUP_SUFFIX = 'org.turtlegit.macos'

def app_group(team):
    # An unsigned build gets an unqualified diagnostic name. Runtime container
    # access explicitly refuses it; never invent a developer-team identity.
    if not team:
        return GROUP_SUFFIX
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Use the actual ten-character Apple developer team ID.')
    return team + '.' + GROUP_SUFFIX

def mach_service(team):
    return app_group(team) + '.cache'


def query_mach_service(team):
    return app_group(team) + '.cache.query'
