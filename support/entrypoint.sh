#!/usr/bin/env bash

generate_device_x509() {
    signing_certificate_path=$1
    signing_private_key_path=$2
    device_id=$3
    date_from=$4
    date_to=$5

    touch database.txt
    mkdir -p certificates

    openssl ecparam \
    -genkey \
    -name prime256v1 \
    -out device-private-key.pem

    openssl req \
    -key device-private-key.pem \
    -new \
    -out device-certificate-signing-request.pem \
    -subj "/CN=${device_id}"

    openssl ca \
    -batch \
    -cert "${signing_certificate_path}" \
    -config openssl.cnf \
    -enddate "${date_to}" \
    -extensions end_entity_certificate_extensions \
    -in device-certificate-signing-request.pem \
    -keyfile "${signing_private_key_path}" \
    -out device-certificate.pem \
    -startdate "${date_from}" > /dev/null 2>&1

    echo "Generated device certificate: ${device_id}"
}

add_days_to_date() {
    local input_date=$1
    local days=$2
    # Validate that the days argument is an integer
    if [[ ! "$days" =~ ^-?[0-9]+$ ]]; then
        echo "Error: The second argument must be an integer."
        return 1
    fi
    
    if [[ $input_date =~ ^[0-9]{8}[0-9]{6}Z$ ]]; then
        # Validate if it is a real date and time
        if ! date -u -d "${input_date:0:8} ${input_date:8:2}:${input_date:10:2}:${input_date:12:2}" >/dev/null 2>&1; then
            echo "The date $input_date is not a valid date."
            return 1
        fi
    else
        echo "The date $input_date is not a valid date."
            return 1
    fi
    
    year=${input_date:0:4}
    month=${input_date:4:2}
    day=${input_date:6:2}
    hour=${input_date:8:2}
    minute=${input_date:10:2}
    second=${input_date:12:2}
    formatted_input="${year}-${month}-${day} ${hour}:${minute}:${second} UTC"

    new_date=$(date -u -d "$formatted_input + $days days" +"%Y%m%d%H%M%SZ")
    echo "$new_date"
}

# Device ID Passed in directly as base64 encoded PEM
if [[ -n "${PERIDIO_PRIVATE_KEY}" && -n "${PERIDIO_CERTIFICATE}" ]]; then
    echo "${PERIDIO_CERTIFICATE}" | base64 --decode 2>/dev/null >> device-certificate.pem
    echo "${PERIDIO_PRIVATE_KEY}" | base64 --decode 2>/dev/null >> device-private-key.pem
    device_id=$(openssl x509 -in device-certificate.pem -noout -subject | sed -n '/^subject/s/^.*CN=//p')
    echo "Device Identity: ${device_id}"
    
# Device ID to be generated using signing certificate / private-key for JITP
elif [[ -n "${PERIDIO_SIGNING_PRIVATE_KEY}" && -n "${PERIDIO_SIGNING_CERTIFICATE}" ]]; then
    signing_certificate=$(echo "${PERIDIO_SIGNING_CERTIFICATE}" | base64 --decode 2>/dev/null)
    signing_private_key=$(echo "${PERIDIO_SIGNING_PRIVATE_KEY}" | base64 --decode 2>/dev/null)
    signing_certificate_path="${PWD}/signing-certificate.pem"
    signing_private_key_path="${PWD}/signing-private-key.pem"
    
    echo "${signing_certificate}" >> ${signing_certificate_path}
    echo "${signing_private_key}" >> ${signing_private_key_path}

    device_id=${PERIDIO_DEVICE_ID:-$(uuidgen)}
    validity=${PERIDIO_VALID_DAYS:-30}
    from_date=$(date -u -d "yesterday 00:00:00" +"%Y%m%d%H%M%SZ")
    to_date=$(add_days_to_date "$from_date" ${validity})
    
    generate_device_x509 "${signing_certificate_path}" "${signing_private_key_path}" "${device_id}" "${from_date}" "${to_date}"
    export PERIDIO_CERTIFICATE=$(base64 -w 0 device-certificate.pem)
    export PERIDIO_PRIVATE_KEY=$(base64 -w 0 device-private-key.pem)
    echo "Device Identity: ${device_id}"

# Device ID Unset
else
    echo "Device Identity Unset"
    echo "set --env PERIDIO_CERTIFICATE | PERIDIO_PRIVATE_KEY to set identity"
    echo "set --env PERIDIO_SIGNING_CERTIFICATE | PERIDIO_SIGNING_PRIVATE_KEY to JITP identity"
fi

exec "$@"
