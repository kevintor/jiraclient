#!/usr/bin/python
#
# jiraclient.py
#
# A Python Jira REST Client
#
# (C) 2007,2008,2009,2010,2011,2012: Matthew Callaway
#
# jiraclient is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2, or (at your option) any later version.
#
# jiraclient.py is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You may have received a copy of the GNU General Public License along with
# jiraclient.py.  If not, write to the Free Software Foundation, Inc., 59
# Temple Place - Suite 330, Boston, MA 02111-1307, USA.

import getpass
import os
import pprint
import re
import sys
import logging, logging.handlers
from stat import *
from optparse import OptionParser,OptionValueError
import ConfigParser
import types
import json
import base64
import datetime
from restkit import Resource, BasicAuth, request
from restkit import TConnectionManager
from restkit.errors import Unauthorized

pp = pprint.PrettyPrinter(indent=4)
time_rx = re.compile('^\d+[mhdw]$')
session_rx = re.compile("session timed out")

def time_is_valid(value):
  m = time_rx.search(value)
  if not m:
    return False
  return True

def inspect(obj,padding=None):
  # Traverse an object printing non-private attributes
  if padding is None:
    padding = 5
  if type(obj) is types.StringType:
    print "%s%s" % (' ' * padding,obj)
  elif type(obj) is types.NoneType:
    print "%s%s" % (' ' * padding,'None')
  else:
    for attr in dir(obj):
      if attr.startswith('_'): continue
      a = getattr(obj,attr)
      if callable(a): continue
      print "%s%s: %s" % (' ' * padding,attr,a)

class Attribute(object):
  required = False
  name = None
  value = None
  def __init__(self,name=None,value=None,required=False):
    self.name = name
    self.value = value
    self.required = required
  def __repr__(self):
    return self.value

class Issue(object):

  def __init__(self):
    self.summary      = ''
    self.environment  = ''
    self.description  = ''
    self.duedate      = ''
    self.project      = { 'id': None }
    self.issuetype    = { 'id': None }
    self.assignee     = { 'name': None }
    self.priority     = { 'id': None }
    self.timetracking = { }
    self.labels       = []
    self.versions     = [ { 'id': None } ]
    self.fixVersions  = [ { 'id': None } ]
    self.components   = [ { 'id': None } ]

  def __repr__(self):
    text = "%s(" % (self.__class__.__name__)
    for attr in dir(self):
      if attr.startswith('_'): continue
      a = getattr(self,attr)
      if callable(a): continue
      text += "%s=%r," % (attr,a)
    text += ")"
    return text

  def update(self,key,value):
    # FIXME: remove unless this expands to handle complex data type attributes
    setattr(self,key,value)

class SearchableDict(dict):
  def find_key(self,val):
      """return the key of dictionary dic given the value"""
      return [k for k, v in self.iteritems() if v == val].pop()
  def find_value(self,key):
      """return the value of dictionary dic given the key"""
      return self[key]

class Jiraclient(object):

  version = "2.0.0"

  def __init__(self):
    self.pool    = TConnectionManager()
    self.proxy   = Resource('', pool_instance=self.pool, filters=[])
    self.pool    = None
    self.restapi = None
    self.token   = None
    self.maps    = {
      'project'    : SearchableDict(),
      'priority'   : SearchableDict(),
      'issuetype'  : SearchableDict(),
      'versions'   : SearchableDict(),
      'fixversions': SearchableDict(),
      'components' : SearchableDict(),
      'resolutions': SearchableDict()
    }

  def fatal(self,msg=None):
    self.logger.fatal(msg)
    sys.exit(1)

  def print_version(self):
    print "jiraclient version %s" % self.version

  def parse_args(self):
    usage = """%prog [options]

 Sample Usage:
  - Standard issue creation in project named INFOSYS:
    jiraclient.py -u 'username' -p 'jirapassword' -A 'auser' -P INFOSYS -T task -S 'Do some task'

 - Get numerical Version IDs for Project named INFOSYS:
   jiraclient.py -u 'username' -p 'jirapassword' -a getVersions INFOSYS

 - Get numerical Component IDs for Project named INFOSYS:
   jiraclient.py -u 'username' -p 'jirapassword' -a getComponents INFOSYS

 - Create an issue with a specified Component and Fix Version 
   and assign it to myself:
   jiraclient.py -u 'username' -p 'jirapassword' -A 'username' -P INFOSYS -Q major -F 10000  -C 10003 -T epic -S 'Investigate Platform IFS'
"""
    optParser = OptionParser(usage)
    optParser.add_option(
      "--config",
      action="store",
      dest="config",
      help="Read configuration from this file",
      default=os.path.join(os.environ["HOME"],'.jiraclientrc'),
    )
    optParser.add_option(
      "--sessionfile",
      action="store",
      dest="sessionfile",
      help="Store authentication token in this file",
      default=os.path.join(os.environ["HOME"],'.jira-session'),
    )
    optParser.add_option(
      "-a","--api",
      action="store",
      dest="api",
      help="Call this API method",
      default=None,
    )
    optParser.add_option(
      "-c","--comment",
      action="store",
      dest="comment",
      help="Comment text",
      default=None,
    )
    optParser.add_option(
      "-l","--loglevel",
      type="choice",
      choices=["CRITICAL","ERROR","WARNING","INFO","DEBUG"],
      dest="loglevel",
      help="Set the log level",
      default="INFO",
    )
    optParser.add_option(
      "--link",
      action="store",
      dest="link",
      help="Given link=A,Depends,B links issues A and B with linktype Depends",
      default=None,
    )
    #optParser.add_option(
    #  "--unlink",
    #  action="store",
    #  dest="unlink",
    #  help="Given unlink=A,B unlink issues A and B",
    #  default=None,
    #)
    optParser.add_option(
      "--subtask",
      action="store",
      dest="subtask",
      help="Given subtask=A,B Make issue B into a sub-task of A",
      default=None,
    )
    optParser.add_option(
      "--template",
      action="store",
      dest="template",
      help="Make a set of Issues based on a YAML template file",
      default=None,
    )
    optParser.add_option(
      "-n","--noop",
      action="store_true",
      dest="noop",
      help="Parse bug file but don't connect to Jira",
      default=False,
    )
    optParser.add_option(
      "-u","--user",
      action="store",
      dest="user",
      help="Jira user",
      default=None,
    )
    optParser.add_option(
      "-p","--password",
      action="store",
      dest="password",
      help="Jira password",
      default=None,
    )
    optParser.add_option(
      "-d","--display",
      action="store_true",
      dest="display",
      help="Display an existing given Jira issue ID",
      default=False,
    )
    optParser.add_option(
      "-i","--issue",
      action="store",
      dest="issueID",
      help="Jira issue ID (to modify)",
      default=None,
    )
    optParser.add_option(
      "-r","--remaining",
      action="store",
      dest="remaining",
      help="Jira issue time 'remaining estimate'",
      default=None,
    )
    optParser.add_option(
      "-s","--spent",
      action="store",
      dest="timespent",
      help="Jira issue 'time spent'",
      default=None,
    )
    optParser.add_option(
      "-R","--resolve",
      action="store",
      dest="resolve",
      help="Resolve issue with the given resolution, eg: 'fixed','incomplete',etc.",
      default=None,
    )
    optParser.add_option(
      "-t","--time",
      action="store",
      dest="timetracking",
      help="Jira issue time 'original estimate'",
      default=None,
    )
    optParser.add_option(
      "-A","--assignee",
      action="store",
      dest="assignee",
      help="Jira assignee",
      default=None,
    )
    optParser.add_option(
      "-C","--components",
      action="store",
      dest="components",
      help="Jira project components, comma separated list",
      default=None,
    )
    optParser.add_option(
      "-D","--description",
      action="store",
      dest="description",
      help="Jira issue description text",
      default=None,
    )
    optParser.add_option(
      "-E","--environment",
      action="store",
      dest="environment",
      help="Jira environment",
      default=None,
    )
    optParser.add_option(
      "-F","--fixVersions",
      action="store",
      dest="fixVersions",
      help="Jira project 'fix versions', comma separated list",
      default=None,
    )
    optParser.add_option(
      "-H","--epic","--epic-theme",
      action="store",
      dest="epic_theme",
      help="Set the epic/theme for the issue",
      default=None,
    )
    optParser.add_option(
      "-P","--project",
      action="store",
      dest="project",
      help="Jira project",
      default=None,
    )
    optParser.add_option(
      "-Q","--priority",
      action="store",
      dest="priority",
      help="Issue priority name",
      default=None,
    )
    optParser.add_option(
      "-S","--summary",
      action="store",
      dest="summary",
      help="Issue summary",
      default=None,
    )
    optParser.add_option(
      "-T","--issuetype",
      action="store",
      dest="issuetype",
      help="Issue type",
      default=None,
    )
    optParser.add_option(
      "-U","--jiraurl",
      action="store",
      dest="jiraurl",
      help="The Jira URL",
      default=None,
    )
    optParser.add_option(
      "-V","--affecstVersions",
      action="store",
      dest="affectsVersions",
      help="Jira project 'affects versions', comma separated list",
      default=None,
    )
    optParser.add_option(
      "--subtask-of",
      action="store",
      dest="subtask_of",
      help="Make the new issue a subtask of this issue key",
      default=None,
    )
    optParser.add_option(
      "--epic-theme-id",
      action="store",
      dest="epic_theme_id",
      help="Jira project 'Epic/Theme', custom field ID for the project (eg. customfield_10010)",
      default="customfield_10010",
    )
    optParser.add_option(
      "--prefix",
      action="store",
      dest="prefix",
      help="Specify prefix text to prepend to all Issue summaries",
      default=None,
    )
    optParser.add_option(
      "--syslog",
      action="store_true",
      dest="use_syslog",
      help="Use syslog",
      default=False,
    )
    optParser.add_option(
      "-v","--version",
      action="store_true",
      dest="version",
      help="Version information",
      default=False,
    )
    optParser.add_option(
      "-w","--worklog",
      action="store",
      dest="worklog",
      help="Log work with this given text string, use this in conjunction with --spent and --remaining",
      default=None,
    )
    optParser.add_option(
      "--delete",
      action="store_true",
      dest="delete",
      help="Delete the issue specified by --issue",
      default=False,
    )
    (self.options, self.args) = optParser.parse_args()

  def prepare_logger(self):
    """prepares a logger optionally to use syslog and with a log level"""
    (use_syslog,loglevel) = (self.options.use_syslog,self.options.loglevel)

    logger = logging.getLogger("jiraclient")
    if use_syslog:
      handler = logging.handlers.SysLogHandler(address="/dev/log")
    else:
      handler = logging.StreamHandler()

    datefmt = "%b %d %H:%M:%S"
    fmt = "%(asctime)s %(name)s[%(process)d]: %(levelname)s: %(message)s"
    fmtr = logging.Formatter(fmt,datefmt)
    handler.setFormatter(fmtr)
    logger.handlers = []
    logger.addHandler(handler)
    logger.setLevel(logging._levelNames[loglevel])
    self.logger = logger

  def read_config(self):
    self.logger.debug("read config %s" % self.options.config)
    parser = ConfigParser.ConfigParser()
    parser.optionxform = str

    if self.options.config is not None:

      if not os.path.exists(self.options.config):
        # Write a basic rc file
        fd = open(self.options.config,'w')
        fd.write('# .jiraclientrc\n')
        fd.write('[jiraclient]\n')
        fd.write('jiraurl = \n')
        fd.write('user = %s\n' % os.environ["USER"])
        fd.write('[issues]\n')
        fd.write('#project = INFOSYS\n')
        fd.write('#type = story\n')
        fd.write('#priority = Normal\n')
        fd.write('#epic_theme = \n')
        fd.write('#assignee = \n')
        fd.write('#components = \n')
        fd.write('#fixVersions = \n')
        fd.close()
        os.chmod(self.options.config,int("600",8))

      if S_IMODE(os.stat(self.options.config).st_mode) != int("600",8):
        self.logger.warning("Config file %s is not mode 600" % (self.options.config))
      try:
        parser.readfp(file(self.options.config,'r'))
      except ConfigParser.ParsingError:
        self.logger.warning("Body has multiple lines, truncating...")
      except Exception, details:
        self.fatal("Unable to parse file at %r: %s" % (self.options.config,details))

    for (k,v) in (parser.items('jiraclient')):
      if not hasattr(self.options,k) or getattr(self.options,k) is None:
        setattr(self.options,k,v)

  def read_issue_defaults(self):

    self.logger.debug("read config %s" % self.options.config)
    parser = ConfigParser.ConfigParser()
    parser.optionxform = str
    try:
      parser.readfp(file(self.options.config,'r'))
    except ConfigParser.ParsingError:
      self.logger.warning("Body has multiple lines, truncating...")
    except Exception, details:
      self.fatal("Unable to parse file at %r: %s" % (self.options.config,details))

    for (k,v) in (parser.items('issues')):
      if not hasattr(self.options,k):
        # You can't set in rcfile something that isn't also an option.
        self.fatal("Unknown issue attribute: %s" % k)
      if getattr(self.options,k) is None:
        # Take the rc file value if not given on CLI
        self.logger.debug("set %s %s" % (k,v))
        setattr(self.options,k,v)

  def call_api(self,method,uri,payload=None):
    self.proxy.uri = "%s/%s" % (self.options.jiraurl, uri)
    call = getattr(self.proxy,method)
    headers = {'Content-Type' : 'application/json'}
    if self.token is not None:
      headers['Authorization'] = 'Basic %s' % self.token
    try:
      self.logger.debug("calling %s %s" % (method.upper(),self.proxy.uri))
      response = call(headers=headers,payload=payload)
    except Unauthorized:
      if os.path.exists(self.options.sessionfile):
        os.unlink(self.options.sessionfile)
      self.fatal("Login failed")
    except Exception,msg:
      self.fatal("Unhandled API exception for method: %s: %s" % (self.proxy.uri,msg))
    try:
      data = json.loads(response.body_string())
      return data
    except ValueError:
      # No json
      return
      pass

  def get_project_id(self,projectKey):
    uri = "%s/%s" % ('rest/api/latest/project', projectKey)
    data = self.call_api("get",uri)
    self.maps['project'][int(data["id"])] = projectKey.lower()

  def get_issue_types(self,projectKey):
    self.check_auth()
    uri = '''%s?projectKeys=%s''' % ('rest/api/latest/issue/createmeta', projectKey)
    data = self.call_api("get",uri)
    for item in data['projects'][0]['issuetypes']:
      #self.maps['issuetype'][str(item['name'].lower())] = int(item['id'])
      self.maps['issuetype'][int(item['id'])] = str(item['name'].lower())

  def get_resolutions(self):
    uri = 'rest/api/latest/resolution'
    data = self.call_api("get",uri)
    for item in data:
      #self.maps['resolutions'][str(item['name'].lower())] = int(item['id'])
      self.maps['resolutions'][int(item['id'])] = str(item['name'].lower()) 

  def get_project_versions(self,projectKey):
    uri = "%s/%s/%s" % ('rest/api/latest/project', projectKey, 'versions')
    data = self.call_api("get",uri)
    for item in data:
      self.maps['versions'][int(item['id'])] = str(item['name'].lower())
    self.maps['fixversions'] = self.maps['versions']

  def get_project_components(self,projectKey):
    uri = "%s/%s/%s" % ('rest/api/latest/project', projectKey, 'components')
    data = self.call_api("get",uri)
    for item in data:
      self.maps['components'][int(item['id'])] = str(item['name'].lower())

  def get_priorities(self):
    uri = 'rest/api/latest/priority'
    data = self.call_api("get",uri)
    for item in data:
      #self.maps['priority'][str(item['name'].lower())] = int(item['id'])
      self.maps['priority'][int(item['id'])] = str(item['name'].lower())

  def get_serverinfo(self):
    uri = 'rest/api/latest/serverInfo'
    return self.call_api("get",uri)

  def get_issue(self,issueID):
    uri = 'rest/api/latest/issue/%s' % issueID
    result = self.call_api("get",uri)
    return result

  def delete_issue(self,issueID):
    uri = 'rest/api/latest/issue/%s?deleteSubtasks' % issueID
    self.call_api('delete',uri)
    print "Deleted %s/browse/%s" % \
     (self.get_serverinfo()['baseUrl'], issueID)

  def resolve_issue(self,issueID,resolution):
    resolution_id = self.maps['resolutions'].find_key(resolution)
    uri = 'rest/api/latest/issue/%s/transitions' % issueID
    payload = json.dumps({"id": resolution_id})
    result = self.call_api("post",uri,payload=payload)
    print "Resolved %s/browse/%s" % \
     (self.get_serverinfo()['baseUrl'], issueID)
    pp.pprint(result)
    return result

  def display_issue(self,issueID):
    uri = 'rest/api/latest/issue/%s' % issueID
    result = self.call_api('get',uri)
    pp.pprint(result)

  def add_comment(self,issueID,comment):
    uri = 'rest/api/latest/issue/%s/comment' % issueID
    comment = json.dumps({'body':comment})
    result = self.call_api('post',uri,payload=comment)
    return result

  def create_issue(self,issueObj):
    issue = issueObj.__dict__
    for k,v in issue.items():
      if not v: issue.pop(k)
      if v == {"id":None}: issue.pop(k)
      if v == [{"id":None}]: issue.pop(k)
    data = json.dumps({"fields":issue})
    print "Create issue:"
    pp.pprint(data)
    if self.options.noop:
      # return a fake Issue Key
      return 'KEY'
    uri = 'rest/api/latest/issue'
    newissue = self.call_api('post',uri,payload=data)
    issueID = newissue["key"]
    print "Created %s/browse/%s" % \
     (self.get_serverinfo()['baseUrl'], issueID)
    return issueID

  def get_issue_links(self,issueID,linktype=None):
    uri = 'rest/api/latest/issue/%s' % issueID
    data = self.call_api('get',uri)
    return data['fields']['issuelinks']

  def modify_issue(self,issueID,issueObj):
    uri = 'rest/api/latest/issue/%s' % issueID
    payload = json.dumps(issueObj)
    self.call_api('post',uri,payload=payload)
    print "Modified %s/browse/%s" % \
      (self.get_serverinfo()['baseUrl'], issueID)

  def get_session(self):
    uri = 'rest/auth/latest/session'
    try:
      self.call_api("get",uri)
    except:
      if os.path.exists(self.options.sessionfile):
        os.unlink(self.options.sessionfile)
      self.fatal("Login failed")

  def read_password(self):
    if not self.options.password:
      print "Please authenticate."
      pw = getpass.getpass("Jira password: ")
      self.options.password = pw

  def check_auth(self):
    session = self.options.sessionfile
    if os.path.exists(session):
      if S_IMODE(os.stat(session).st_mode) != int("600",8):
        self.logger.error("session file %s is not mode 600, forcing new session" % (session))
        os.unlink(session)

    token = None
    if not os.path.exists(session):
      self.logger.debug("make auth token")
      if not self.options.password:
        self.read_password()
      token = base64.b64encode("%s:%s" % (self.options.user, self.options.password))
    else:
      self.logger.debug("read auth token")
      fd = open(session,'r')
      token = fd.read()
      fd.close()

    self.token = token
    self.get_session()
    fd = open(session,'w')
    fd.write(token)
    fd.close()
    os.chmod(session,int("600",8))

  def update_issue_obj(self,issue,key,value):
    # This method handles Issue's complex attribute types.
    #
    # Input values come from CLI or rc file, so are all strings
    # potentially with comma separated lists.  To keep things
    # simple, let's just assume all CLI and rc file input are not lists.
    #
    # Use case examples:
    #   summary is a string
    #   project is a dict with id
    #   versions is a list of dicts with id

    attr = getattr(issue,key)

    # Does the 'key' exist in self.maps to provide an ID?
    attribute_map = None
    if self.maps.has_key(key.lower()):
      attribute_map = self.maps[key.lower()]
      attribute_id = attribute_map.find_key(value.lower())
      if not attribute_id:
        self.logger.debug("no id found for %s" % (value.lower()))
        return
    else:
      self.logger.debug("no map found for %s" % (key.lower()))
      attribute_id = value.lower()

    # Plain string assignment
    if type(attr) is str:
      setattr(issue,key,str(value))

    # Lists might be lists of strings or lists of dicts
    # 'labels' is the only list of just strings
    if type(attr) is list:
      if key == 'labels':
        attr.append(str(value))
      else:
        try:
          attr.pop(attr.index({'id':None}))
        except Exception: pass
        attr.append({'id':str(attribute_id)})

    if type(attr) is dict:
      #self.logger.debug("set dict attr %s %s" % (key,value))
      item = getattr(issue,key)
      if item.has_key('id'):
        if attribute_map:
          item['id'] = str(attribute_id)
        else:
          item['id'] = str(value)
      if item.has_key('name'):
        item['name'] = str(value)

    return issue

  def create_issue_obj(self,defaults=False):
    # Trigger to parse rc file for issue default values
    if defaults:
      self.read_issue_defaults()

    if self.options.project is None:
      self.fatal("You must specify a project key")

    # Creates an Issue object based on CLI args and config file.
    # We do this for create and modify operations.
    issue = Issue()

    self.get_project_id(self.options.project)
    self.get_issue_types(self.options.project)
    self.get_project_versions(self.options.project)
    self.get_project_components(self.options.project)
    self.get_resolutions()
    self.get_priorities()

    for key in issue.__dict__.keys():
      #self.logger.debug("attr %s" % key)
      if hasattr(self.options,key):
        attr = getattr(self.options,key)
        if attr:
          values = getattr(self.options,key).split(',')
          for value in values:
            issue = self.update_issue_obj(issue,key,value)

    if self.options.epic_theme:
      setattr(issue,self.options.epic_theme_id,self.options.epic_theme)

    if self.options.timetracking:
      issue.timetracking = { "originalEstimate": self.options.timetracking }
    if self.options.remaining:
      issue.timetracking = { "remainingEstimate": self.options.remaining }

    return issue

  def log_work(self,issueID):
    '''/rest/api/2/issue/{issueIdOrKey}/worklog?adjustEstimate&newEstimate&reduceBy'''
    comment = self.options.worklog
    spent = self.options.timespent
    if spent is not None:
      m = time_rx.match(spent)
      if not m:
        self.logger.warning("Time spent has dubious format: %s: no action taken" % (spent))
        return
    remaining = self.options.remaining
    if remaining is not None:
      m = time_rx.match(remaining)
      if not m:
        self.logger.warning("Time remaining has dubious format: %s: no action taken" % (remaining))
        return

    self.logger.info("Update work log for %s: %s" % (issueID,comment))
    baseuri = 'rest/api/2/issue/%s/worklog' % issueID
    dt_today = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f-0000");

    if spent is None and remaining is None:
      worklog = {'startDate':dt_today,'comment':comment}
      payload = json.dumps(worklog)
      self.call_api('post',baseuri,payload=payload)
    elif spent is None:
      # remaining has been set, but not spent
      uri = "%s?adjustEstimate=new&newEstimate=%s" % (baseuri,remaining)
      worklog = {'startDate':dt_today,'comment':comment}
      payload = json.dumps(worklog)
      self.call_api('post',uri,payload=payload)
    elif remaining is None:
      # spent set, auto adjust
      uri = "%s?adjustEstimate=auto" % (baseuri)
      worklog = {'startDate':dt_today,'timeSpent':spent,'comment':comment}
      payload = json.dumps(worklog)
      self.call_api('post',uri,payload=payload)
    else:
      # spent set and remaining set
      uri = "%s?adjustEstimate=new&newEstimate=%s" % (baseuri,remaining)
      worklog = {'startDate':dt_today,'timeSpent':spent,'comment':comment}
      payload = json.dumps(worklog)
      self.call_api('post',uri,payload=payload)

  def link_issues(self,issueFrom,linkType,issueTo):
    if self.options.noop:
      print "Would link %s -> %s" % (issueFrom,issueTo)
      return
    uri = 'rest/api/latest/issueLink'
    payload = json.dumps({"type":{"name":linkType},"inwardIssue":{"key":issueFrom},"outwardIssue":{"key":issueTo},"comment":{"body":self.options.comment}})
    result = self.call_api('post',uri,payload=payload)
    return result

  #def unlink_issues(self,issueFrom,linkType,issueTo):
  #  if self.options.noop:
  #    print "Would unlink %s -> %s" % (parent,child)
  #    return
  #  result = self.proxy.unlinkIssue(self.auth,fromId,toId,linkType)
  #  return result

  def subtask_link(self,parent,child):
    if self.options.noop:
      print "Would apply subtask link"
      return
    # issueType is always jira_subtask_link, which we get from the Jira DB:
    # mysql> select * from issuelinktype;
    # +-------+-------------------+---------------------+----------------------+--------------+
    # | ID    | LINKNAME          | INWARD              | OUTWARD              | pstyle       |
    # +-------+-------------------+---------------------+----------------------+--------------+
    # | 10010 | Duplicate         | is duplicated by    | duplicates           | NULL         | 
    # | 10000 | jira_subtask_link | jira_subtask_inward | jira_subtask_outward | jira_subtask | 
    # | 10011 | Depends           | is depended on by   | depends on           | NULL         | 
    # | 10012 | Blocks            | is blocked by       | blocks               | NULL         | 
    # +-------+-------------------+---------------------+----------------------+--------------+
    # 4 rows in set (0.00 sec)
    result = self.link_issues(child,'jira_subtask_link',parent)
    return result

  def run(self):

    self.parse_args()

    if self.options.version:
      self.print_version()
      return

    self.prepare_logger()
    self.read_config()

    if not self.options.user:
      self.fatal("Please specify Jira user")

    if not self.options.jiraurl:
      self.fatal("Please specify the Jira URL")

    # Check or get auth token
    self.check_auth()

    # Run a named Jira API call and return
    if self.options.api is not None:
      try:
        data = self.call_api('get',self.options.api)
      except Exception, details:
        self.fatal("API error: bad method: %s" % details)
      pp.pprint(data)
      return

    if self.options.delete is True:
      self.delete_issue(self.options.issueID)
      return

    if self.options.display:
      self.display_issue(self.options.issueID)
      return

    ## Create a set of Issues based on a YAML project file
    #if self.options.template is not None:
    #  self.create_issues_from_template()
    #  return

    # Link two existing IDs
    if self.options.link is not None:
      (fromId,linktype,toId) = self.options.link.split(',')
      print "Create '%s' link from '%s' to '%s'" % (linktype,fromId,toId)
      self.link_issues(fromId,linktype,toId)
      return

    # UnLink two existing IDs
    #if self.options.unlink is not None:
    #  (fromId,linktype,toId) = self.options.unlink.split(',')
    #  print "Remove '%s' link from '%s' to '%s'" % (linktype,fromId,toId)
    #  result = self.unlink_issues(fromId,linktype,toId)
    #  return

    # Make one issue a sub-task of another
    if self.options.subtask is not None:
      (parent,child) = self.options.subtask.split(',')
      print "Make '%s' a subtask of '%s'" % (child,parent)
      result = self.subtask_link(parent,child)
      return

    # Comment on an existing issue ID
    if self.options.comment is not None and self.options.issueID is not None:
      if self.options.noop:
        print "Add comment to %s: %s" % (self.options.issueID,self.options.comment)
      else:
        self.add_comment(self.options.issueID,self.options.comment)

    # Update time remaining of given issue
    if self.options.worklog is not None and self.options.issueID is not None:
      if self.options.noop:
        print "Update time estimate for %s: %s" % (self.options.issueID,self.options.remaining)
      else:
        self.log_work(self.options.issueID)

    # Resolve a given existing issue ID
    if self.options.issueID is not None and self.options.resolve is not None:
      if self.options.noop:
        print "Resolve %s %s" % (self.options.issueID,self.options.resolve)
        return
      self.resolve_issue(self.options.issueID,self.options.resolve)
      return

    # We've done all we're allowed to do with a given existing issueID
    if self.options.issueID is not None:
        return

    # Modify existing issue
    if self.options.issueID is not None:
      issue = self.create_issue_obj(defaults=False)
      self.modify_issue(self.options.issueID,issue)
      return

    # Create a new issue
    issue = self.create_issue_obj(defaults=True)
    try:
      issueID = self.create_issue(issue)
    except Exception, details:
      self.fatal("Failed to create issue. Reason: %r" % details)

    # Make the issue a subtask, if a parent is given
    if self.options.subtask_of:
      self.subtask_link(self.options.subtask_of,issueID)

    # Add a work log, possibly updating remaining estimate
    if self.options.worklog is not None:
      self.log_work(issueID)

    # Immediately resolve it if specified
    if self.options.resolve is not None:
      self.resolve_issue(issueID,self.options.resolve)

def main():
  A = Jiraclient()
  try:
    A.run()
  except KeyboardInterrupt:
    print "Exiting..."
    return

if __name__ == "__main__":
  main()

