#!/bin/bash
# Copyright or © or Copr. Pierre Capillon, 2012.
# 
# pierre.capillon@ssi.gouv.fr
# 
# This software is a computer program whose purpose is to retrieve Active
# Directory objects permissions from an ESENT database file.
# 
# This software is governed by the CeCILL license under French law and
# abiding by the rules of distribution of free software.  You can  use, 
# modify and/ or redistribute the software under the terms of the CeCILL
# license as circulated by CEA, CNRS and INRIA at the following URL
# "http://www.cecill.info". 
# 
# As a counterpart to the access to the source code and  rights to copy,
# modify and redistribute granted by the license, users are provided only
# with a limited warranty  and the software's author,  the holder of the
# economic rights,  and the successive licensors  have only  limited
# liability. 
# 
# In this respect, the user's attention is drawn to the risks associated
# with loading,  using,  modifying and/or developing or reproducing the
# software by the user in light of its specific status of free software,
# that may mean  that it is complicated to manipulate,  and  that  also
# therefore means  that it is reserved for developers  and  experienced
# professionals having in-depth computer knowledge. Users are therefore
# encouraged to load and test the software's suitability as regards their
# requirements in conditions enabling the security of their systems and/or 
# data to be ensured and,  more generally, to use and operate it in the 
# same conditions as regards security. 
# 
# The fact that you are presently reading this means that you have had
# knowledge of the CeCILL license and that you accept its terms.
# 

if [ $# -ne 1 ]; then
	echo "Usage: $0 <mode>"
	echo "<mode>	Join query mode: "
	echo "	\"fast\":	does only a single outer join to spare CPU time"
	echo "	\"full\":	does a double outer join to put static common-names as TrusteeCN"
	echo "	\"none\":	does not join objects and security descriptors tables"
	exit 1
fi

OWN_PATH="`dirname \"$0\"`"
OWN_PATH="`( cd \"$OWN_PATH\" && pwd )`"
if [ -z "$OWN_PATH" ] ; then
  exit 1
fi

login=`grep 'import_user' "$OWN_PATH/../www/settings.php" | cut -d'"' -f2`
pass=`grep 'import_pass' "$OWN_PATH/../www/settings.php" | cut -d'"' -f2`
database=`grep 'import_database' "$OWN_PATH/../www/settings.php" | cut -d'"' -f2`

parser="$OWN_PATH/scripts/generic_scripts/auto.sh"
ts=`date +"%Y%m%d_%H%M%S"`
table_obj="${ts}_Objects"
table_ace="${ts}_SecurityDescriptor"

# Import Objects
if [ -f "./data/obj-ntds.dit-dump.csv" ]; then
	echo "Importing objects..."
	$parser "$OWN_PATH/data/obj-ntds.dit-dump.csv" "[$ts] Objects" "$OWN_PATH/../www/" "$table_obj"
fi

# Import security descriptors
if [ -f "./data/ace-ntds.dit-dump.csv" ]; then
	echo "Importing security descriptors..."
	$parser "$OWN_PATH/data/ace-ntds.dit-dump.csv" "[$ts] Security Descriptors" "$OWN_PATH/../www/" "$table_ace"
fi

# Create indexes to speed up left outer join
echo "Creating indexes on joined attributes..."
echo "*** THIS MIGHT TAKE SOME TIME (hint: watch mysql process status) ***"

echo "ALTER TABLE  \`$table_ace\` ADD INDEX (  \`sd_id\` ) ;" > ./tmp/indexes.sql
echo "ALTER TABLE  \`$table_ace\` ADD INDEX (  \`TrusteeSID\` ) ;" > ./tmp/indexes.sql
echo "ALTER TABLE  \`$table_obj\` ADD INDEX (  \`msExchMailboxSecurityDescriptor\` ) ;" >> ./tmp/indexes.sql
echo "ALTER TABLE  \`$table_obj\` ADD INDEX (  \`nTSecurityDescriptor\` ) ;" >> ./tmp/indexes.sql

mysql -u $login -p$pass $database < "./tmp/indexes.sql"

# temporary files
mkdir -p tmp

# Import categories to auditad.ObjectCategory
echo "Populating global table of categories..."

echo "CREATE TABLE IF NOT EXISTS \`ObjectCategory\` (
  \`lDAPDisplayName\` varchar(255) NOT NULL,
  \`defaultObjectCategory\` int(11) NOT NULL,
  KEY \`defaultObjectCategory\` (\`defaultObjectCategory\`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;
INSERT INTO ObjectCategory 
SELECT \`lDAPDisplayName\`, \`defaultObjectCategory\` 
FROM $table_obj WHERE \`defaultObjectCategory\` != 0;" > ./tmp/object_category.sql

mysql -u $login -p$pass $database < "./tmp/object_category.sql"

# Import GUIDs to auditad.GUID
echo "Populating global table of GUIDs..."
echo "CREATE TABLE IF NOT EXISTS \`GUID\` (
  \`value\` varchar(255) DEFAULT NULL,
  \`text\` varchar(255) DEFAULT NULL,
  PRIMARY KEY (\`value\`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

INSERT INTO GUID(\`value\`,\`text\`)
SELECT \`rightsGuid\`, \`distinguishedName\` 
FROM $table_obj WHERE \`rightsGuid\` IS NOT NULL 
	AND \`rightsGuid\` != '';

INSERT INTO GUID(\`value\`,\`text\`)
SELECT \`schemaIDGuid\`, \`distinguishedName\` 
FROM $table_obj WHERE \`schemaIDGuid\` IS NOT NULL 
	AND \`schemaIDGuid\` != '0'
	AND \`schemaIDGuid\` != '00000000-0000-0000-0000-000000000000';" > ./tmp/guid.sql

mysql -u $login -p$pass $database < "./tmp/guid.sql"

# Import SIDs to auditad.SID
echo "Populating global table of SIDs..."
echo "CREATE TABLE IF NOT EXISTS \`SID\` (
  \`distinguishedName\` varchar(200) NOT NULL,
  \`objectSID\` varchar(100) NOT NULL,
  PRIMARY KEY ( \`objectSID\` ) 
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

INSERT IGNORE INTO SID(\`distinguishedName\`,\`objectSID\`)
SELECT \`distinguishedName\`, \`objectSID\` 
FROM $table_obj WHERE \`objectSID\` LIKE 'S-%';" > ./tmp/sid.sql

mysql -u $login -p$pass $database < "./tmp/sid.sql"

# Join queries to precompute ACE tables

# MS Exchange-related table
query_exch="INSERT INTO \`ACE_EXCH\` (
 \`distinguishedName\`, \`objectCategory\`, \`objectSID\`,
 \`sd_id\`, \`PrimaryOwner\`, \`PrimaryGroup\`, \`AceType\`,
 \`AceFlags\`, \`AccessMask\`, \`Flags\`, \`ObjectType\`,
 \`InheritedObjectType\`, \`TrusteeSID\`, \`TrusteeDN\`
)
SELECT 
 S1.\`distinguishedName\`,
 S1.\`objectCategory\`,
 S1.\`objectSID\`,
 A.\`sd_id\`,
 A.\`PrimaryOwner\`,
 A.\`PrimaryGroup\`,
 A.\`AceType\`,
 A.\`AceFlags\`,
 A.\`AccessMask\`,
 A.\`Flags\`,
 A.\`ObjectType\`,
 A.\`InheritedObjectType\`,
 A.\`TrusteeSID\`,
 S2.\`distinguishedName\` AS \`TrusteeDN\`
FROM $table_obj S1
LEFT OUTER JOIN $table_ace A ON (S1.\`msExchMailboxSecurityDescriptor\` = A.\`sd_id\`)
LEFT OUTER JOIN SID S2 ON (S2.\`objectSID\` = A.\`TrusteeSID\`);"

# MS Exchange-related table # FASTER VERSION (NO static TrusteeDN)
query_exch_fast="INSERT INTO \`ACE_EXCH\` (
 \`distinguishedName\`, \`objectCategory\`, \`objectSID\`,
 \`sd_id\`, \`PrimaryOwner\`, \`PrimaryGroup\`, \`AceType\`,
 \`AceFlags\`, \`AccessMask\`, \`Flags\`, \`ObjectType\`,
 \`InheritedObjectType\`, \`TrusteeSID\`
)
SELECT 
 S1.\`DistinguishedName\`,
 S1.\`objectCategory\`,
 S1.\`objectSID\`,
 A.\`sd_id\`,
 A.\`PrimaryOwner\`,
 A.\`PrimaryGroup\`,
 A.\`AceType\`,
 A.\`AceFlags\`,
 A.\`AccessMask\`,
 A.\`Flags\`,
 A.\`ObjectType\`,
 A.\`InheritedObjectType\`,
 A.\`TrusteeSID\`
FROM $table_obj S1
LEFT OUTER JOIN $table_ace A ON (S1.\`msExchMailboxSecurityDescriptor\` = A.\`sd_id\`);"

# AD-related table
query_ad="INSERT INTO \`ACE_AD\` (
 \`distinguishedName\`, \`objectCategory\`, \`objectSID\`,
 \`sd_id\`, \`PrimaryOwner\`, \`PrimaryGroup\`, \`AceType\`,
 \`AceFlags\`, \`AccessMask\`, \`Flags\`, \`ObjectType\`,
 \`InheritedObjectType\`, \`TrusteeSID\`, \`TrusteeDN\`
)
SELECT 
 S1.\`distinguishedName\`,
 S1.\`objectCategory\`,
 S1.\`objectSID\`,
 A.\`sd_id\`,
 A.\`PrimaryOwner\`,
 A.\`PrimaryGroup\`,
 A.\`AceType\`,
 A.\`AceFlags\`,
 A.\`AccessMask\`,
 A.\`Flags\`,
 A.\`ObjectType\`,
 A.\`InheritedObjectType\`,
 A.\`TrusteeSID\`,
 S2.\`distinguishedName\` AS \`TrusteeDN\`
FROM $table_obj S1
LEFT OUTER JOIN $table_ace A ON (S1.\`nTSecurityDescriptor\` = A.\`sd_id\`)
LEFT OUTER JOIN SID S2 ON (S2.\`objectSID\` = A.\`TrusteeSID\`);"

# AD-related table # FASTER VERSION (NO static TrusteeDN)
query_ad_fast="INSERT INTO \`ACE_AD\` (
 \`distinguishedName\`, \`objectCategory\`, \`objectSID\`,
 \`sd_id\`, \`PrimaryOwner\`, \`PrimaryGroup\`, \`AceType\`,
 \`AceFlags\`, \`AccessMask\`, \`Flags\`, \`ObjectType\`,
 \`InheritedObjectType\`, \`TrusteeSID\`
)
SELECT 
 S1.\`distinguishedName\`,
 S1.\`objectCategory\`,
 S1.\`objectSID\`,
 A.\`sd_id\`,
 A.\`PrimaryOwner\`,
 A.\`PrimaryGroup\`,
 A.\`AceType\`,
 A.\`AceFlags\`,
 A.\`AccessMask\`,
 A.\`Flags\`,
 A.\`ObjectType\`,
 A.\`InheritedObjectType\`,
 A.\`TrusteeSID\`
FROM $table_obj S1
LEFT OUTER JOIN $table_ace A ON (S1.\`nTSecurityDescriptor\` = A.\`sd_id\`);"

# Precompute tables

# Empty AD & EXCH tables
if [ "$1" != "none" ]; then
	echo "Emptying destination tables..."
	echo "TRUNCATE TABLE \`ACE_AD\`;
TRUNCATE TABLE \`ACE_EXCH\`;" > ./tmp/empty.sql

	mysql -u $login -p$pass $database < "./tmp/empty.sql"
fi

# FULL QUERIES
if [ "$1" = "full" ]; then
	echo $query_ad > ./tmp/join_ad.sql
	echo $query_exch > ./tmp/join_exch.sql
	echo "Computing AD-related table..."
	echo "*** THIS MIGHT TAKE SOME TIME (hint: watch mysql process status) ***"
	mysql -u $login -p$pass $database < "./tmp/join_ad.sql"
	echo "Computing MS Exchange-related table..."
	echo "*** THIS MIGHT TAKE SOME TIME (hint: watch mysql process status) ***"
	mysql -u $login -p$pass $database < "./tmp/join_exch.sql"
fi

# FAST QUERIES
if [ "$1" = "fast" ]; then
	echo $query_ad_fast > ./tmp/join_ad.sql
	echo $query_exch_fast > ./tmp/join_exch.sql
	echo "Computing AD-related table..."
	echo "*** THIS MIGHT TAKE SOME TIME (hint: watch mysql process status) ***"
	mysql -u $login -p$pass $database < "./tmp/join_ad.sql"
	echo "Computing MS Exchange-related table..."
	echo "*** THIS MIGHT TAKE SOME TIME (hint: watch mysql process status) ***"
	mysql -u $login -p$pass $database < "./tmp/join_exch.sql"
fi


